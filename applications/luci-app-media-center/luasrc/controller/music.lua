-- 音乐中心（Music Center）公开接口
--
-- 目标：让 888 端口的静态页面在不登录 LuCI 的情况下，读取并控制本机的
--       OwnTone / GMediaRender / AirPlay(shairport-sync) 三个音乐服务。
--
-- 路径放在 /cgi-bin/luci/music/*，不带 admin 前缀，因此不需要 LuCI 会话；
-- 安全边界完全由本文件负责：
--   1) 只接受内网来源（IPv4 私有地址 / 回环 / IPv6；公网 IPv4 一律拒绝）；
--   2) 写操作必须是 POST；带 Origin 的浏览器请求必须与 Host 同源，
--      防止别的网页跨站偷偷控制家里的音箱；
--   3) 所有 shell 参数都做白名单或转义。
--
-- 注意：888 端口本身由 /etc/config/uhttpd 的段提供，本文件只负责 API。

module("luci.controller.music", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local sys = require "luci.sys"
local nixio = require "nixio"
local fs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()

local SND_CACHE = "/tmp/music-center-sndcard"
local GMR_LAST_DL = "/tmp/gmediarender_last_dl.txt"
local OWNTONE_MUTE_STATE = "/tmp/music-center-owntone-mute"

-- 歌曲封面：与歌曲同目录、同名的 jpg/png/webp
local function urlencode(s)
    return (tostring(s):gsub("([^%w%-%._~])", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end))
end

local function cover_allowed(path)
    if path == "" then return false end
    local dirs = tostring(uci:get_first("owntone", "owntone", "directories") or "")
    for raw_d in dirs:gmatch("[^:%s]+") do
        local d = tostring(raw_d):gsub("/+$", "")
        if d ~= "" and path:sub(1, #d + 1) == d .. "/" then return true end
    end
    return false
end

local function cover_sidecar(path)
    if not cover_allowed(path) then return nil, nil end
    local base = path:gsub("%.[%w]+$", "")
    for _, ext in ipairs({ "jpg", "jpeg", "png", "webp" }) do
        local p = base .. "." .. ext
        if fs.access(p) then return p, ext end
    end
    return nil, nil
end

function index()
    entry({"music", "status"}, call("action_status")).leaf = true
    entry({"music", "control"}, post("action_control")).leaf = true
    entry({"music", "volume"}, post("action_volume")).leaf = true
    entry({"music", "autoplay"}, post("action_autoplay")).leaf = true
    entry({"music", "library"}, post("action_library")).leaf = true
    entry({"music", "monitor"}, call("action_monitor")).leaf = true
    entry({"music", "service"}, post("action_service")).leaf = true
    entry({"music", "download"}, post("action_download")).leaf = true
    entry({"music", "download_log"}, call("action_download_log")).leaf = true
    entry({"music", "cover"}, call("action_cover")).leaf = true
    entry({"music", "coverfetch"}, post("action_cover_fetch")).leaf = true
    entry({"music", "soundcards"}, call("action_soundcards")).leaf = true
    entry({"music", "soundcard"}, post("action_soundcard")).leaf = true
end

-------------------------------------------------------------------------------
-- 小工具
-------------------------------------------------------------------------------

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shell_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function respond(ok, err)
    http.prepare_content("application/json")
    http.write(jsonc.stringify({ ok = ok and true or false, error = err or nil }))
end

local function json_error(code, msg)
    http.status(code)
    http.prepare_content("application/json")
    http.write(jsonc.stringify({ ok = false, error = msg }))
end

local function require_post()
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        http.status(405)
        http.header("Allow", "POST")
        http.prepare_content("application/json")
        http.write('{"ok":false,"error":"请使用 POST 请求"}')
        return false
    end
    return true
end

local function uci_get(cfg, typ, opt, default)
    local v = uci:get_first(cfg, typ, opt)
    if v == nil or v == "" then return default end
    return tostring(v)
end

local function plugin_enabled(cfg, typ)
    local v = tostring(uci_get(cfg, typ, "enabled", "0")):lower()
    return v == "1" or v == "true" or v == "yes" or v == "on"
end

local function process_running(name)
    return sys.call("pidof " .. name .. " >/dev/null 2>&1") == 0
end

local function installed(bin, cfg)
    return (bin and fs.access(bin)) or (cfg and fs.access(cfg)) or false
end

-- 把 UCI 里某个匿名 section 的 enabled 选项写成 value（不重启服务）
local function set_plugin_enabled(cfg, typ, value)
    local changed = false
    uci:foreach(cfg, typ, function(s)
        uci:set(cfg, s[".name"], "enabled", value)
        changed = true
        return false
    end)
    if changed then uci:commit(cfg) end
    return changed
end

-------------------------------------------------------------------------------
-- 来源校验
--
-- 不要求密码，所以必须至少做到“内网可用、外网不可用、跨站不可写”。
-- IPv6 不在这里按私网前缀卡死：很多家庭宽带给内网设备分配的是全球单播地址，
-- 真正的外网边界交给 OpenWrt 防火墙（WAN 默认 REJECT）。公网 IPv4 直接拒绝。
-------------------------------------------------------------------------------

local function ip_is_private(ip)
    if not ip or ip == "" then return false end
    local mapped = ip:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
    if mapped then ip = mapped end

    if ip == "127.0.0.1" or ip == "::1" then return true end
    if ip:match("^10%.") or ip:match("^192%.168%.") or ip:match("^169%.254%.") then return true end

    local second = tonumber(ip:match("^172%.(%d+)%."))
    if second and second >= 16 and second <= 31 then return true end

    -- 100.64.0.0/10（运营商级 NAT / 部分随身路由）
    local cgnat = tonumber(ip:match("^100%.(%d+)%."))
    if cgnat and cgnat >= 64 and cgnat <= 127 then return true end

    -- IPv6：回环、ULA、链路本地，以及内网常见的全球单播，均放行
    if ip:find(":", 1, true) then
        if ip:match("^[fF][cCdD]") or ip:match("^[fF][eE][89abAB]") then return true end
        return true
    end
    return false
end

-- 反向代理会把真实客户端地址放到 X-Real-IP / X-Forwarded-For；
-- 只有请求确实来自本机反向代理时才信任，避免直接访问 80 时伪造。
local function client_ip()
    local raddr = http.getenv("REMOTE_ADDR") or ""
    if raddr == "127.0.0.1" or raddr == "::1" then
        local real = http.getenv("HTTP_X_REAL_IP") or ""
        if real == "" then
            local xff = http.getenv("HTTP_X_FORWARDED_FOR") or ""
            local last
            for ip in xff:gmatch("[^,%s]+") do last = ip end
            real = last or ""
        end
        if real ~= "" then return real end
    end
    return raddr
end

local function normalize_host(host)
    host = (host or ""):lower()
    local bracketed = host:match("^%[([^%]]+)%]")
    if bracketed then return bracketed end
    local _, colons = host:gsub(":", "")
    if colons <= 1 then host = host:gsub(":%d+$", "") end
    return host
end

local function host_is_lan(host)
    if not host or host == "" then return false end
    host = normalize_host(host)
    if host == "localhost" or host == "::1" then return true end
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return ip_is_private(host) end
    if host:find(":", 1, true) then return ip_is_private(host) end
    if host:match("^[^.]+$") then return true end
    return host:match("%.local$") ~= nil or host:match("%.lan$") ~= nil
        or host:match("%.home$") ~= nil or host:match("%.internal$") ~= nil
        or host:match("%.home%.arpa$") ~= nil
end

local function guard(write)
    if not ip_is_private(client_ip()) then
        json_error(403, "音乐中心仅限局域网访问")
        return false
    end

    if write then
        local origin = http.getenv("HTTP_ORIGIN") or ""
        if origin ~= "" then
            local ohost = origin:match("^https?://([^/]+)$")
            local hhost = http.getenv("HTTP_HOST") or ""
            if not ohost or not host_is_lan(ohost) or not host_is_lan(hhost)
                or normalize_host(ohost) ~= normalize_host(hhost) then
                json_error(403, "拒绝跨站控制请求")
                return false
            end
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- 网络
-------------------------------------------------------------------------------

local _lan_ip
local function lan_ip()
    if _lan_ip then return _lan_ip end
    local ip = uci:get("network", "lan", "ipaddr")
    if ip and ip:match("^%d+%.%d+%.%d+%.%d+$") then
        _lan_ip = ip
        return ip
    end
    local ok, ifs = pcall(nixio.getifaddrs)
    if ok and type(ifs) == "table" then
        for _, ifa in ipairs(ifs) do
            if ifa.name == "br-lan" and ifa.family == "inet"
                and ifa.addr and ifa.addr ~= "" then
                _lan_ip = ifa.addr
                return ifa.addr
            end
        end
    end
    _lan_ip = "127.0.0.1"
    return _lan_ip
end

-- 只取 Host 里的主机部分：uhttpd 传 Host 时本来就不带端口，
-- 直连 LuCI 80 时可能带 :80，这里统一剥掉；IPv6 的方括号要保留。
local function host_only()
    local h = http.getenv("HTTP_HOST") or ""
    if h == "" then return "" end
    local bracketed = h:match("^(%[[^%]]+%])")
    if bracketed then return bracketed end
    return (h:gsub(":%d+$", ""))
end

local function dechunk(body)
    local out, pos = {}, 1
    while true do
        local e = body:find("\r\n", pos, true)
        if not e then break end
        local size = tonumber(body:sub(pos, e - 1):gsub(";.*$", ""), 16)
        if not size or size == 0 then break end
        out[#out + 1] = body:sub(e + 2, e + 1 + size)
        pos = e + 2 + size + 2
    end
    return table.concat(out)
end

-- 极简 HTTP 客户端：只访问 127.0.0.1/局域网，不处理重定向、Cookie。
-- 返回 body, status_code, err
local function http_send(method, host, port, path, body, ctype, extra_headers, timeout)
    local sock = nixio.socket("inet", "stream")
    if not sock then return nil, nil, "socket" end
    local t = timeout or 1
    pcall(function() sock:setopt("socket", "rcvtimeo", t) end)
    pcall(function() sock:setopt("socket", "sndtimeo", t) end)

    local ok = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, nil, "connect"
    end

    local req = method .. " " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. host .. ":" .. tostring(port) .. "\r\n"
        .. "User-Agent: music-center/1.0\r\n"
        .. "Accept: */*\r\n"
        .. "Connection: close\r\n"
    if ctype then req = req .. "Content-Type: " .. ctype .. "\r\n" end
    if extra_headers then req = req .. extra_headers end
    if body then
        req = req .. "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
    else
        req = req .. "Content-Length: 0\r\n\r\n"
    end

    if not sock:send(req) then
        sock:close()
        return nil, nil, "send"
    end

    local chunks, total = {}, 0
    while true do
        local data = sock:recv(8192)
        if not data or data == "" then break end
        chunks[#chunks + 1] = data
        total = total + #data
        if total > 512 * 1024 then break end
    end
    sock:close()

    local resp = table.concat(chunks)
    local head, payload = resp:match("^(.-)\r\n\r\n(.*)$")
    if not head then return nil, nil, "response" end
    local code = tonumber(head:match("^HTTP/%d%.%d%s+(%d+)"))
    if head:lower():find("transfer%-encoding:%s*chunked") then
        payload = dechunk(payload or "")
    end
    return payload or "", code
end

local function http_get(host, port, path, timeout)
    local body, code = http_send("GET", host, port, path, nil, nil, nil, timeout)
    if not body or not code or code < 200 or code >= 300 then return nil end
    return body
end

local function http_put(host, port, path, timeout)
    local _, code = http_send("PUT", host, port, path, nil, nil, nil, timeout)
    return code == 200 or code == 204
end

local function http_post(host, port, path, timeout)
    local _, code = http_send("POST", host, port, path, nil, nil, nil, timeout)
    return code == 200 or code == 204
end

-------------------------------------------------------------------------------
-- 物理声卡音量
-------------------------------------------------------------------------------

local function read_snd_cache()
    local st = fs.stat(SND_CACHE)
    if not st or not st.mtime then return nil end
    if os.time() - st.mtime > 60 then return nil end
    local raw = fs.readfile(SND_CACHE) or ""
    -- 文件末尾带换行，第三个字段用 + 而不是 *，否则 $ 匹配不到
    local card, name, control = raw:match("^([^\n]*)\n([^\n]*)\n([^\n]+)")
    if card and card ~= "" and control and control ~= "" then
        return card, name or "", control
    end
    return nil
end

local function write_snd_cache(card, name, control)
    local f = io.open(SND_CACHE, "w")
    if f then
        f:write(tostring(card), "\n", tostring(name or ""), "\n", tostring(control), "\n")
        f:close()
    end
end

local function resolve_soundcard()
    local card, name, control = read_snd_cache()

    if not card then
        local asound = ""
        if fs.access("/etc/asound.conf") then
            asound = fs.readfile("/etc/asound.conf") or ""
        end
        local want = asound:match('pcm%s+"hw:([^,]+),')

        local cards = fs.readfile("/proc/asound/cards") or ""
        local by_name, first_num, first_name = {}, nil, nil
        for num, cname in cards:gmatch("(%d+)%s+%[([^%]]+)%]") do
            cname = trim(cname)
            by_name[cname] = num
            if not first_num then
                first_num, first_name = num, cname
            end
        end

        if want and want:match("^%d+$") then
            card = want
        elseif want and by_name[want] then
            card = by_name[want]
        else
            card = first_num or "0"
        end

        for num, cname in cards:gmatch("(%d+)%s+%[([^%]]+)%]") do
            if num == card then name = trim(cname); break end
        end
        if not name or name == "" then name = first_name or "" end

        local scontrols = sys.exec("amixer -c " .. tostring(card) .. " scontrols 2>/dev/null") or ""
        if scontrols:match("'Headphone'") then control = "Headphone"
        elseif scontrols:match("'Master'") then control = "Master"
        elseif scontrols:match("'PCM'") then control = "PCM"
        elseif scontrols:match("'Speaker'") then control = "Speaker"
        else control = scontrols:match("'([^']+)'") end
        control = control or "Master"

        write_snd_cache(card, name, control)
    end

    local sget = sys.exec("amixer -c " .. tostring(card) .. " sget "
        .. shell_quote(control) .. " 2>/dev/null") or ""
    local volume = tonumber(sget:match("%[(%d+)%%%]")) or 0
    local muted = sget:match("%[off%]") ~= nil

    return {
        available = sget ~= "",
        card = tostring(card),
        name = name or "",
        control = control,
        volume = volume,
        muted = muted,
    }
end

local function list_soundcards()
    local cards = {}
    local raw = fs.readfile("/proc/asound/cards") or ""
    for num, name in raw:gmatch("(%d+)%s+%[([^%]]+)%]") do
        num = tostring(num)
        name = trim(name)
        local controls, seen = {}, {}
        local out = sys.exec("amixer -c " .. num .. " scontrols 2>/dev/null") or ""
        for c in out:gmatch("'([^']+)'") do
            if not seen[c] then
                seen[c] = true
                controls[#controls + 1] = c
            end
        end
        if #controls == 0 then controls = { "Master" } end
        cards[#cards + 1] = { num = tonumber(num), name = name, controls = controls }
    end
    return cards
end

local function set_physical_volume(action, value)
    local info = resolve_soundcard()
    if not info.available then return false, "没有找到可用的声卡混音控制" end

    local cmd
    if action == "mute" then
        cmd = "amixer -c " .. info.card .. " sset " .. shell_quote(info.control) .. " mute"
    elseif action == "unmute" then
        cmd = "amixer -c " .. info.card .. " sset " .. shell_quote(info.control) .. " unmute"
    else
        local v = math.max(0, math.min(100, tonumber(value) or 0))
        cmd = "amixer -c " .. info.card .. " sset " .. shell_quote(info.control)
            .. " " .. tostring(math.floor(v)) .. "% unmute"
    end
    local rc = sys.call(cmd .. " >/dev/null 2>&1")
    if rc ~= 0 then return false, "amixer 执行失败" end
    return true
end

-------------------------------------------------------------------------------
-- OwnTone
-------------------------------------------------------------------------------

local function owntone_port()
    return tonumber(uci_get("owntone", "owntone", "port", "3689")) or 3689
end

local function absolute_art(url, port)
    if not url or url == "" then return "" end
    if url:match("^https?://") then return url end
    if url:sub(1, 1) ~= "/" then url = "/" .. url end
    local h = host_only()
    if h == "" then h = "127.0.0.1" end
    return string.format("http://%s:%d%s", h, port, url)
end

local function log_last_pos(s, needle)
    local pos = nil
    local i = 1
    while true do
        local p = s:find(needle, i, true)
        if not p then break end
        pos = p
        i = p + #needle
    end
    return pos
end

local function owntone_log_tail()
    local path = "/var/log/owntone.log"
    if not fs.access(path) then return "" end
    local stt = fs.stat(path)
    local size = stt and tonumber(stt.size) or 0
    local f = io.open(path, "r")
    if not f then return "" end
    if size > 32768 then f:seek("set", size - 32768) end
    local data = f:read("*a") or ""
    f:close()
    return data
end


local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function probe_channels(path)
    local cache = "/tmp/music-channels.cache"
    local f = io.open(cache, "r")
    if f then
        local line = f:read("*l") or ""
        f:close()
        local p, c = line:match("^(.-)|(%d+)$")
        if p == path then return tonumber(c) or 0 end
    end
    local out = sys.exec("ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 " .. shq(path) .. " 2>/dev/null") or ""
    local ch = tonumber(out:match("%d+")) or 0
    local w = io.open(cache, "w")
    if w then w:write(path .. "|" .. tostring(ch)); w:close() end
    return ch
end

local function cover_stage(path)
    local f = io.open("/tmp/music-cover-stage", "r")
    if not f then return "" end
    local line = f:read("*l") or ""
    f:close()
    local s, p = line:match("^([^|]*)|([^|]*)")
    if p and p == tostring(path or "") then return tostring(s or "") end
    return ""
end

local function owntone_status()

    local port = owntone_port()
    local st = {
        installed = installed("/usr/sbin/owntone", "/etc/config/owntone"),
        enabled = plugin_enabled("owntone", "owntone"),
        running = process_running("owntone"),
        state = "stop",
        playing = false,
        title = "", artist = "", album = "", art = "",
        position = 0, duration = 0, volume = 0,
        format = "", bitrate = 0, samplerate = 0, channels = 0,
        muted = false, mute_volume = 0,
        autoplay = (uci:get_first("owntone", "owntone", "autoplay") == "1"),
        name = tostring(uci:get_first("owntone", "owntone", "player_name") or ""),
        port = port,
        mpd_ok = false,
        scanning = false,
        db_error = false,
        library_count = 0,
    }
    if not st.running then return st end

    local body = http_get(lan_ip(), port, "/api/player", 1)
    if not body then
        st.error = "OwnTone API 无响应"
        return st
    end

    local ok, p = pcall(jsonc.parse, body)
    if not ok or type(p) ~= "table" then
        st.error = "OwnTone API 返回了无法解析的数据"
        return st
    end

    st.mpd_ok = true
    st.state = tostring(p.state or "stop")
    st.playing = (st.state == "play")
    st.volume = tonumber(p.volume) or 0
    local mute_saved = tonumber(fs.readfile(OWNTONE_MUTE_STATE) or "")
    if mute_saved and mute_saved > 0 and st.volume <= 0 then
        st.muted = true
        st.mute_volume = mute_saved
    elseif mute_saved then
        fs.unlink(OWNTONE_MUTE_STATE)
    end
    local log = owntone_log_tail()
    local db_ok = log_last_pos(log, "Database OK") or 0
    local db_err = math.max(
        log_last_pos(log, "database disk image is malformed") or 0,
        log_last_pos(log, "Database init failed") or 0,
        log_last_pos(log, "incompatible database") or 0,
        log_last_pos(log, "Database version check errored") or 0)
    st.db_error = (db_err > 0 and (db_ok == 0 or db_err > db_ok))
    local scan_done = log_last_pos(log, "scan completed") or 0
    local scan_cur = math.max(
        log_last_pos(log, "Scanned") or 0,
        log_last_pos(log, "Scanning") or 0,
        log_last_pos(log, "scan:") or 0)
    st.scanning = (scan_cur > scan_done)
    if st.db_error then st.error = "OwnTone 数据库错误" end

    st.shuffle = (p.shuffle == true)
    st["repeat"] = tostring(p["repeat"] or "off")
    -- OwnTone 的 /api/player 用 item_progress_ms 表示当前进度（position_ms 只用于 seek 参数）
    st.position = (tonumber(p.item_progress_ms) or tonumber(p.position_ms) or 0) / 1000
    st.duration = (tonumber(p.item_length_ms) or 0) / 1000
    local item_id = tonumber(p.item_id)

    if (st.state == "play" or st.state == "pause") and item_id and item_id > 0 then
        local q = http_get(lan_ip(), port, "/api/queue?id=now_playing", 1)
        if q then
            local qok, qd = pcall(jsonc.parse, q)
            if qok and type(qd) == "table" then
                st.library_count = tonumber(qd.count) or 0
                local item = qd.items and qd.items[1] or qd
                if type(item) == "table" then
                    st.title = tostring(item.title or item.name or "")
                    st.artist = tostring(item.artist or "")
                    st.album = tostring(item.album or "")
                    if st.duration <= 0 then
                        st.duration = (tonumber(item.length_ms) or 0) / 1000
                    end
                    local fmt = tostring(item.codec or item.format or "")
                    if fmt == "" then
                        fmt = tostring(item.path or ""):match("%.([%w]+)$") or ""
                    end
                    st.format = fmt:upper()
                    st.bitrate = tonumber(item.bitrate) or 0
                    st.samplerate = tonumber(item.samplerate) or 0
                    st.channels = tonumber(item.channels) or 0
                    st.path = tostring(item.path or item.uri or ""):gsub("^file:/+", "/")
                    if st.channels == 0 and st.path ~= "" then
                        st.channels = probe_channels(st.path)
                    end
                    st.cover_stage = cover_stage(st.path)
                    local own_art = absolute_art(tostring(item.artwork_url or ""), port)
                    -- 优先用同目录同名的封面（音乐中心页面按单曲显示）
                    local has_side = false
                    if st.path ~= "" and cover_allowed(st.path) then
                        local base = st.path:gsub("%.[%w]+$", "")
                        local ts = 0
                        for _, ext in ipairs({ "jpg", "jpeg", "png", "webp" }) do
                            local p = base .. "." .. ext
                            if fs.access(p) then
                                local stt = fs.stat(p)
                                ts = stt and tonumber(stt.mtime) or 0
                                has_side = true
                                break
                            end
                        end
                        if has_side then
                            st.art = "/cgi-bin/luci/music/cover?path=" .. urlencode(st.path)
                                .. "&t=" .. tostring(ts)
                        end
                        if not has_side and fs.access("/usr/bin/music-cover-fetch") then
                            local stamp = "/tmp/music-cover-fetch.stamp"
                            local now = os.time()
                            local last = tonumber(fs.readfile(stamp) or "") or 0
                            if now - last > 120 then
                                fs.writefile(stamp, tostring(now))
                                os.execute(string.format("/usr/bin/music-cover-fetch --one %q %q %q >/dev/null 2>&1 &", st.path, st.artist or "", st.title or ""))
                            end
                        end
                    end
                    if not has_side then st.art = own_art end
                end
            end
        end
    end

    return st
end

local function owntone_control(action, value)
    local port = owntone_port()

    if action == "seek" then
        local sec = tonumber(value) or 0
        if sec < 0 then sec = 0 end
        local ok = http_put(lan_ip(), port,
            "/api/player/seek?position_ms=" .. tostring(math.floor(sec * 1000)), 2)
        return ok, (not ok) and "OwnTone 不支持跳转或接口无响应" or nil
    end

    if action == "shuffle" then
        local state = (value == "true" or value == "1" or value == "on") and "true" or "false"
        local ok = http_put(lan_ip(), port,
            "/api/player/shuffle?state=" .. state, 2)
        return ok, (not ok) and "OwnTone 随机播放接口无响应" or nil
    end

    if action == "repeat" then
        local state = tostring(value or "off")
        if state ~= "all" and state ~= "single" then state = "off" end
        local ok = http_put(lan_ip(), port,
            "/api/player/repeat?state=" .. state, 2)
        return ok, (not ok) and "OwnTone 循环播放接口无响应" or nil
    end

    local map = {
        play = "play",
        pause = "pause",
        toggle = "toggle",
        stop = "stop",
        next = "next",
        previous = "previous",
    }
    local path = map[action]
    if not path then return false, "不支持的播放操作: " .. tostring(action) end

    local ok = http_put(lan_ip(), port, "/api/player/" .. path, 2)
    return ok, (not ok) and "OwnTone 控制接口无响应" or nil
end

local function owntone_set_volume(value)
    local port = owntone_port()
    local v = math.max(0, math.min(100, tonumber(value) or 0))

    -- 设成 0 视为静音：记住静音前的音量，供状态判断与恢复使用
    if v <= 0 then
        local current = 0
        local body = http_get(lan_ip(), port, "/api/player", 1)
        if body then
            local pok, p = pcall(jsonc.parse, body)
            if pok and type(p) == "table" then current = tonumber(p.volume) or 0 end
        end
        local saved = tonumber(fs.readfile(OWNTONE_MUTE_STATE) or "") or 0
        if saved <= 0 then
            if current > 0 then saved = current else saved = 70 end
            fs.writefile(OWNTONE_MUTE_STATE, tostring(math.floor(saved)))
        end
    end

    local ok = http_put(lan_ip(), port,
        "/api/player/volume?volume=" .. tostring(math.floor(v)), 2)
    if ok and v > 0 then fs.unlink(OWNTONE_MUTE_STATE) end
    return ok, (not ok) and "OwnTone 音量接口无响应" or nil
end

local function owntone_mute(action)
    local port = owntone_port()
    local body = http_get(lan_ip(), port, "/api/player", 1)
    local current = 0
    if body then
        local ok, p = pcall(jsonc.parse, body)
        if ok and type(p) == "table" then current = tonumber(p.volume) or 0 end
    end

    if action == "unmute" then
        local saved = tonumber(fs.readfile(OWNTONE_MUTE_STATE) or "") or current
        if saved <= 0 then saved = 70 end
        local ok = http_put(lan_ip(), port,
            "/api/player/volume?volume=" .. tostring(math.floor(saved)), 2)
        if ok then fs.unlink(OWNTONE_MUTE_STATE) end
        return ok, (not ok) and "OwnTone 音量接口无响应" or nil
    end

    if current <= 0 then current = 70 end
    local ok = http_put(lan_ip(), port, "/api/player/volume?volume=0", 2)
    if ok then fs.writefile(OWNTONE_MUTE_STATE, tostring(math.floor(current))) end
    return ok, (not ok) and "OwnTone 音量接口无响应" or nil
end

-------------------------------------------------------------------------------
-- GMediaRender（UPnP AVTransport / RenderingControl）
-------------------------------------------------------------------------------

local function xml_unescape(s)
    s = tostring(s or "")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    return (s:gsub("&amp;", "&"))
end

local function parse_time(t)
    t = trim(t)
    local h, m, s = t:match("^(%d+):(%d+):(%d+)")
    if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
    local mm, ss = t:match("^(%d+):(%d+)$")
    if mm then return tonumber(mm) * 60 + tonumber(ss) end
    return tonumber(t) or 0
end

local function upnp_control(ip, port, action, inner)
    local service = "urn:schemas-upnp-org:service:AVTransport:1"
    local path = "/upnp/control/rendertransport1"
    if action == "GetVolume" or action == "SetVolume" then
        service = "urn:schemas-upnp-org:service:RenderingControl:1"
        path = "/upnp/control/rendercontrol1"
    end

    local body = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:%s xmlns:u="%s">%s</u:%s></s:Body>
</s:Envelope>]], action, service, inner, action)

    local headers = "SOAPAction: \"" .. service .. "#" .. action .. "\"\r\n"
    local resp, code = http_send("POST", ip, port, path, body,
        "text/xml; charset=\"utf-8\"", headers, 1)
    if not resp or not code then return nil end
    return resp, code
end

-- 旧 gmediarender 控制器用 uclient-fetch/wget 的 --post-file 发 SOAP，
-- 这条路在现场是能切歌的；nixio 裸 HTTP/1.0 POST 在部分 libupnp 版本上
-- 会被拒绝（Next/Previous 返回 500）。GMR 控制统一走这里。
local function upnp_fetch(ip, port, action, inner)
    local service = "urn:schemas-upnp-org:service:AVTransport:1"
    local path = "/upnp/control/rendertransport1"
    if action == "GetVolume" or action == "SetVolume" then
        service = "urn:schemas-upnp-org:service:RenderingControl:1"
        path = "/upnp/control/rendercontrol1"
    end

    local body = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:%s xmlns:u="%s">%s</u:%s></s:Body>
</s:Envelope>]], action, service, inner, action)

    local suffix = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    local tmp_in = "/tmp/music-center-gmr-in-" .. suffix .. ".xml"
    local tmp_out = "/tmp/music-center-gmr-out-" .. suffix .. ".xml"

    local f = io.open(tmp_in, "w")
    if not f then return nil end
    f:write(body)
    f:close()

    local tool = nil
    if sys.call("which uclient-fetch >/dev/null 2>&1") == 0 then
        tool = "uclient-fetch"
    elseif sys.call("which wget >/dev/null 2>&1") == 0 then
        tool = "wget"
    end
    if not tool then
        os.remove(tmp_in)
        return nil
    end

    local cmd
    if tool == "uclient-fetch" then
        cmd = string.format("uclient-fetch -q -O %s -T 2 --post-file='%s' --header='SOAPAction: \"%s#%s\"' --header='Content-Type: text/xml; charset=\"utf-8\"' 'http://%s:%d%s' 2>/dev/null",
            tmp_out, tmp_in, service, action, ip, port, path)
    else
        cmd = string.format("wget -q -O %s -T 2 --post-file='%s' --header='SOAPAction: \"%s#%s\"' --header='Content-Type: text/xml; charset=\"utf-8\"' 'http://%s:%d%s' 2>/dev/null",
            tmp_out, tmp_in, service, action, ip, port, path)
    end
    sys.call(cmd)

    local res = ""
    if fs.access(tmp_out) then
        res = fs.readfile(tmp_out) or ""
    end
    os.remove(tmp_in)
    os.remove(tmp_out)
    if res == "" then return nil end
    return res, 200
end

local function gmr_status(ip, port)
    local st = {
        installed = installed("/usr/bin/gmediarender", "/etc/config/gmediarender"),
        enabled = plugin_enabled("gmediarender", "gmediarender"),
        running = process_running("gmediarender"),
        state = "", playing = false,
        title = "", artist = "", album = "", art = "",
        position = 0, duration = 0, volume = 0,
        format = "", media = "", streamurl = "",
        soundcard = "",
        broadcast = uci_get("gmediarender", "gmediarender", "friendly_name", "GMediaRender"),
        auto_download_triggered = false,
        auto_download_file = "",
    }
    if not st.running then return st end

    local info = upnp_control(ip, port, "GetTransportInfo", "<InstanceID>0</InstanceID>")
    if not info then
        st.error = "GMediaRender UPnP 无响应"
        return st
    end
    st.state = info:match("<[^>]*CurrentTransportState[^>]*>([^<]+)<") or ""
    st.playing = (st.state == "PLAYING")

    local pos = upnp_control(ip, port, "GetPositionInfo", "<InstanceID>0</InstanceID>")
    if pos then
        st.position = parse_time(pos:match("<[^>]*RelTime[^>]*>([^<]+)<"))
        st.duration = parse_time(pos:match("<[^>]*TrackDuration[^>]*>([^<]+)<"))

        local meta = pos:match("<[^>]*TrackMetaData[^>]*>([^<]*)</[^>]*TrackMetaData>")
        if meta and meta ~= "" then
            meta = xml_unescape(meta)
            st.title = meta:match("<dc:title>([^<]*)</dc:title>")
                or meta:match("<title>([^<]*)</title>") or ""
            st.artist = meta:match("<upnp:artist>([^<]*)</upnp:artist>")
                or meta:match("<artist>([^<]*)</artist>") or ""
            st.album = meta:match("<upnp:album>([^<]*)</upnp:album>")
                or meta:match("<album>([^<]*)</album>") or ""
            st.art = meta:match("<upnp:albumArtURI>([^<]*)</upnp:albumArtURI>") or ""
            if st.art ~= "" and not st.art:match("^https?://") then st.art = "" end
            st.streamurl = meta:match("<res[^>]*>([^<]*)</res>") or ""
            if st.streamurl == "" then
                st.streamurl = pos:match("<[^>]*TrackURI[^>]*>([^<]*)<") or ""
            end

            local cls = meta:match("<upnp:class>([^<]*)</upnp:class>") or ""
            if cls:match("musicTrack") then st.media = "歌曲"
            elseif cls:match("audioBroadcast") then st.media = "电台"
            elseif cls:match("audioItem") then st.media = "音频" end

            local mime = meta:match('protocolInfo="[^"]*:(audio/[^:;]+)')
                or meta:match("protocolInfo=[\"']audio/([^:;\"']+)")
            if mime then
                local m = mime:lower()
                if m:match("mpeg") then st.format = "MP3"
                elseif m:match("flac") then st.format = "FLAC"
                elseif m:match("mp4") or m:match("m4a") then st.format = "M4A/AAC"
                elseif m:match("wav") then st.format = "WAV"
                elseif m:match("ogg") then st.format = "OGG"
                elseif m:match("opus") then st.format = "OPUS"
                else st.format = mime end
            end
        end
    end

    local vol = upnp_control(ip, port, "GetVolume",
        "<InstanceID>0</InstanceID><Channel>Master</Channel>")
    if vol then
        st.volume = tonumber(vol:match("<[^>]*CurrentVolume[^>]*>([^<]+)<")) or 0
    end

    -- 输出声卡：和原插件页面一致，优先 gmediarender 的 -o/-d 参数，
    -- 没写参数时取 /proc/asound/cards 的第一张卡
    local pid = (sys.exec("pidof gmediarender 2>/dev/null") or ""):match("(%d+)")
    if pid then
        local cmdline = (fs.readfile("/proc/" .. pid .. "/cmdline") or ""):gsub("%z", " ")
        local out_arg = cmdline:match("%-o%s+([%w:%,%-]+)")
            or cmdline:match("%-d%s+([%w:%,%-]+)")
        if out_arg and out_arg ~= "" then st.soundcard = out_arg end
    end
    if st.soundcard == "" then
        local cards = fs.readfile("/proc/asound/cards") or ""
        local card_num, card_name = cards:match("(%d+)%s+%[.-%]:.-%-%s+([^\n]+)")
        if card_num and card_name then
            st.soundcard = "hw:" .. card_num .. " (" .. trim(card_name) .. ")"
        end
    end

    return st
end

local function gmr_control(action, value)
    local ip, port = lan_ip(), tonumber(uci_get("gmediarender", "gmediarender", "port", "49152")) or 49152
    local instance = "<InstanceID>0</InstanceID>"
    local resp, code

    if action == "play" then
        resp, code = upnp_control(ip, port, "Play", instance .. "<Speed>1</Speed>")
    elseif action == "pause" then
        resp, code = upnp_control(ip, port, "Pause", instance)
    elseif action == "stop" then
        resp, code = upnp_control(ip, port, "Stop", instance)
    elseif action == "next" then
        resp, code = upnp_control(ip, port, "Next", instance)
    elseif action == "previous" then
        resp, code = upnp_control(ip, port, "Previous", instance)
    elseif action == "seek" then
        local sec = math.max(0, tonumber(value) or 0)
        local h = math.floor(sec / 3600)
        local m = math.floor((sec % 3600) / 60)
        local s = math.floor(sec % 60)
        local target = string.format("%02d:%02d:%02d", h, m, s)
        resp, code = upnp_control(ip, port, "Seek",
            instance .. "<Unit>REL_TIME</Unit><Target>" .. target .. "</Target>")
    elseif action == "volume" then
        local v = math.max(0, math.min(100, tonumber(value) or 0))
        resp, code = upnp_control(ip, port, "SetVolume",
            instance .. "<Channel>Master</Channel><DesiredVolume>"
            .. tostring(math.floor(v)) .. "</DesiredVolume>")
    else
        return false, "不支持的 DLNA 操作: " .. tostring(action)
    end

    if not resp then return false, "GMediaRender 无响应" end
    -- 老版 nowplaying.htm 的 action_control 只判断 success=(res~=nil)，
    -- 不解析 SOAP 里的 500/701。很多 DLNA 渲染器在“手机端没有队列”时
    -- 会对 Next/Previous 返回 701，这里保持老行为：只要收到响应就算已发送，
    -- 避免切歌按钮每次点击都弹错误。
    if action == "next" or action == "previous" then
        return true
    end
    if code and code >= 200 and code < 300 then return true end

    local labels = {
        next = "下一曲", previous = "上一曲", seek = "跳转",
        volume = "音量", play = "播放", pause = "暂停", stop = "停止",
    }
    local label = labels[action] or action
    local errcode = resp:match("<errorCode>(%d+)</errorCode>")
    if errcode == "701" then
        return false, "当前 DLNA 推送端不支持" .. label .. "（播放队列在手机端）"
    end
    if code == 500 or code == 501 then
        return false, "当前 DLNA 推送端不支持" .. label
    end
    return false, "GMediaRender 返回 " .. tostring(code or "未知状态")
end

-- 保留原插件的“播放时自动下载”：以前由 LuCI 的 nowplaying 轮询触发，
-- 现在由音乐中心的状态轮询触发；只有打开音乐中心页面时才会执行，
-- 和旧行为一致（旧页面关闭后同样不会继续下载）。
local function trigger_download(url, title, artist, cover)
    url = tostring(url or ""):gsub("&amp;", "&")
    if not url:match("^https?://") then return false, "无效链接" end

    local tool
    if sys.call("which wget >/dev/null 2>&1") == 0 then tool = "wget"
    elseif sys.call("which uclient-fetch >/dev/null 2>&1") == 0 then tool = "uclient-fetch" end
    if not tool then return false, "无下载工具" end

    local dir = uci_get("gmediarender", "gmediarender", "download_dir", "")
    if dir == "" then return false, "下载路径未配置" end
    if not dir:match("^/mnt") then return false, "下载目录必须在 /mnt 下" end
    if not fs.access(dir) then return false, "下载目录不存在" end

    local function sanitize(s)
        s = tostring(s or ""):gsub("[\\/:*?\"<>|]", "_")
        return trim(s)
    end

    local safe_title = sanitize(title)
    local safe_artist = sanitize(artist)
    if safe_title == "暂无播放" or safe_title == "空闲" then safe_title = "" end
    if safe_artist == "-" or safe_artist == "未知艺术家" then safe_artist = "" end

    local filename
    if safe_title ~= "" and safe_artist ~= "" then
        filename = safe_title .. "-" .. safe_artist
    elseif safe_title ~= "" then
        filename = safe_title
    else
        filename = url:match("([^/]+)$") or "download_song"
    end

    local ext = url:gsub("%?.*$", ""):match("%.([%a%d]+)$")
    if not ext or #ext > 4 then ext = "mp3" end
    if not filename:match("%.%w+$") then filename = filename .. "." .. ext end

    local filepath = dir .. "/" .. filename

    -- 封面优先取 DLNA 元数据里的 albumArtURI；本地源再兜底从文件提取
    local playsrc = ""

    local script = [[
#!/bin/sh
LOG=/tmp/gmediarender_dl.log
PROGF=/tmp/gmr_progress.txt
URL=@URL@
OUT=@OUT@
COVER=@COVER@
PLAYSRC=@PLAYSRC@
TMP="$OUT.part"
EXT=${OUT##*.}
FTMP="$OUT.part.$EXT"
COVERFILE=/tmp/gmr_cover.jpg

: > "$LOG"
: > "$PROGF"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
human() { awk -v s="$1" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(s>=1024&&i<5){s/=1024;i++}printf "%.1f %s",s,u[i]}'; }

log "文件: $(basename "$OUT")"
log "位置: $(dirname "$OUT")"

rm -f "$TMP" "$FTMP" "$COVERFILE"

# ---------- 1) 先取封面 ----------
if [ -n "$COVER" ]; then
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$COVERFILE" "$COVER" 2>/dev/null
    else
        uclient-fetch -q -O "$COVERFILE" "$COVER" 2>/dev/null
    fi
fi
if [ ! -s "$COVERFILE" ] && [ -n "$PLAYSRC" ] && [ -f "$PLAYSRC" ]; then
    ffmpeg -hide_banner -loglevel error -nostats -y -i "$PLAYSRC" -an -vcodec mjpeg -frames:v 1 "$COVERFILE" >/dev/null 2>&1
fi

case "$OUT" in
    *.mp3|*.m4a|*.mp4|*.m4b|*.aac|*.flac) FMT=1 ;;
    *) FMT=0 ;;
esac

if [ -s "$COVERFILE" ]; then
    log "封面: 已获取 ($(human "$(wc -c < "$COVERFILE" | tr -d ' ')"))"
else
    log "封面: 未获取"
fi
if [ -s "$COVERFILE" ] && [ "$FMT" = "1" ]; then
    log "可嵌入: 是"
else
    log "可嵌入: 否"
fi

# ---------- 2) 一次落盘（带实时进度） ----------
if [ -s "$COVERFILE" ] && [ "$FMT" = "1" ] && command -v ffmpeg >/dev/null 2>&1; then
    log "下载并嵌入封面（单次写盘）"
    DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$URL" 2>/dev/null)
    rm -f /tmp/gmr_ffprog
    case "$OUT" in
        *.mp3)
            ffmpeg -hide_banner -loglevel error -nostats -progress /tmp/gmr_ffprog -stats_period 1 -y \
                -i "$URL" -i "$COVERFILE" -map 0:a -map 1:v -c copy -id3v2_version 3 \
                -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" "$FTMP" >>"$LOG" 2>&1 &
            ;;
        *)
            ffmpeg -hide_banner -loglevel error -nostats -progress /tmp/gmr_ffprog -stats_period 1 -y \
                -i "$URL" -i "$COVERFILE" -map 0:a -map 1:v -c copy -disposition:v:0 attached_pic "$FTMP" >>"$LOG" 2>&1 &
            ;;
    esac
    FFPID=$!
    while kill -0 "$FFPID" 2>/dev/null; do
        sleep 1
        TT=$(sed -n 's/^out_time_ms=//p' /tmp/gmr_ffprog 2>/dev/null | tail -1)
        SS=$(sed -n 's/^total_size=//p' /tmp/gmr_ffprog 2>/dev/null | tail -1)
        if [ -n "$TT" ] && [ -n "$DUR" ]; then
            awk -v t="$TT" -v d="$DUR" -v s="$SS" 'BEGIN{ if(d>0){ p=t/1000000/d*100; if(p>100)p=100; if(p<0)p=0; printf "%d|%d\n", p, s } }' > "$PROGF" 2>/dev/null
        fi
    done
    wait "$FFPID" 2>/dev/null
    : > "$PROGF"

    if [ -s "$FTMP" ]; then
        mv -f "$FTMP" "$TMP"
    fi
    if [ ! -s "$TMP" ]; then
        log "ffmpeg 直接下载失败，退回普通下载"
        rm -f "$TMP" "$FTMP"
        if command -v wget >/dev/null 2>&1; then
            wget -O "$TMP" "$URL" >>"$LOG" 2>&1
        else
            uclient-fetch -O "$TMP" "$URL" >>"$LOG" 2>&1
        fi
    fi
else
    log "下载（不嵌封面）"
    if command -v wget >/dev/null 2>&1; then
        wget -O "$TMP" "$URL" >>"$LOG" 2>&1
    else
        uclient-fetch -O "$TMP" "$URL" >>"$LOG" 2>&1
    fi
fi

if [ ! -s "$TMP" ]; then
    log "下载失败"
    log "状态: 失败"
    rm -f "$TMP" "$FTMP" "$COVERFILE"
    : > "$PROGF"
    exit 1
fi

NEWSZ=$(wc -c < "$TMP" | tr -d ' ')

# ---------- 3) 判重 ----------
if [ -f "$OUT" ]; then
    OLDSZ=$(wc -c < "$OUT" | tr -d ' ')
    HASCOVER=0
    if command -v ffprobe >/dev/null 2>&1; then
        if ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "$OUT" 2>/dev/null | grep -q .; then
            HASCOVER=1
        fi
    fi
    if [ "$HASCOVER" = "1" ] && [ "$OLDSZ" = "$NEWSZ" ]; then
        log "已存在且带封面、大小一致，跳过覆盖"
        log "大小: $NEWSZ 字节 ($(human "$NEWSZ"))"
        log "状态: 已跳过"
        rm -f "$TMP" "$FTMP" "$COVERFILE"
        exit 0
    fi
    if [ "$HASCOVER" = "1" ]; then
        log "已有封面但大小不同（旧 $(human "$OLDSZ") / 新 $(human "$NEWSZ")）"
    else
        log "旧文件无封面（旧 $(human "$OLDSZ") / 新 $(human "$NEWSZ")）"
    fi
fi

mv -f "$TMP" "$OUT"
log "大小: $NEWSZ 字节 ($(human "$NEWSZ"))"
log "已带封面: $([ -s "$COVERFILE" ] && echo 是 || echo 否)"
log "状态: 完成"
rm -f "$COVERFILE" "$FTMP"
: > "$PROGF"
exit 0
]]
    local function fill(s)
        s = s:gsub("@URL@", shell_quote(url))
        s = s:gsub("@OUT@", shell_quote(filepath))
        s = s:gsub("@COVER@", shell_quote(tostring(cover or "")))
        s = s:gsub("@PLAYSRC@", shell_quote(playsrc))
        s = s:gsub("@TOOL@", tool)
        return s
    end

    local spath = "/tmp/gmr_dl_" .. tostring(os.time()) .. ".sh"
    local fh = io.open(spath, "w")
    if not fh then return false, "无法写入下载脚本" end
    fh:write(fill(script))
    fh:close()

    sys.call("chmod +x " .. shell_quote(spath))
    sys.call("( /bin/sh " .. shell_quote(spath) .. " >/dev/null 2>&1 & )")
    return true, filename
end
local function maybe_auto_download(st)
    if not st.playing then return false end
    if not st.streamurl or not st.streamurl:match("^https?://") then return false end
    if tostring(uci_get("gmediarender", "gmediarender", "auto_download", "0")) ~= "1" then
        return false
    end

    local last = ""
    if fs.access(GMR_LAST_DL) then last = trim(fs.readfile(GMR_LAST_DL) or "") end
    if last == st.streamurl then return false end

    local f = io.open(GMR_LAST_DL, "w")
    if f then f:write(st.streamurl); f:close() end

    local ok, file = trigger_download(st.streamurl, st.title, st.artist, st.art)
    return ok, file
end

-------------------------------------------------------------------------------
-- AirPlay / shairport-sync
-------------------------------------------------------------------------------

local function shairport_status()
    local st = {
        installed = installed("/usr/bin/shairport-sync", "/etc/config/shairport-sync"),
        enabled = plugin_enabled("shairport-sync", "shairport-sync"),
        running = process_running("shairport-sync"),
        playing = false,
        title = "", artist = "", album = "", lyric = "",
        volume = 0, client = "", client_ip = "",
        broadcast = uci_get("shairport-sync", "shairport-sync", "name", "AirPlay 2"),
        port = tonumber(uci_get("shairport-sync", "shairport-sync", "port", "5050")) or 5050,
        soundcard = "",
        cover = "", cover_ts = 0,
    }

    if fs.access("/tmp/shairport-now.json") then
        local raw = fs.readfile("/tmp/shairport-now.json") or "{}"
        local ok, d = pcall(jsonc.parse, raw)
        if ok and type(d) == "table" then
            st.title = tostring(d.title or "")
            st.artist = tostring(d.artist or "")
            st.album = tostring(d.album or "")
            st.lyric = tostring(d.lyric or "")
            st.volume = tonumber(d.volume) or 0
            st.client = tostring(d.snam or "")
            st.client_ip = tostring(d.clip or "")
            st.soundcard = tostring(d.soundcard or "")
            st.cover_ts = tonumber(d.cover_ts) or 0
            st.playing = (d.playing == true) and st.running
            if d.has_cover then
                st.cover = "/cgi-bin/luci/music/cover?service=shairport&t="
                    .. tostring(st.cover_ts)
            end
        end
    end
    if not st.running then st.playing = false end
    return st
end

-------------------------------------------------------------------------------
-- 聚合状态
-------------------------------------------------------------------------------

local function safe_call(fn, fallback, ...)
    local ok, res = pcall(fn, ...)
    if ok and type(res) == "table" then return res end
    local t = fallback or {}
    t.error = tostring(res)
    return t
end

------------------------------------------------------------------------------
-- 声卡设置（从 media-center-owntone 的声卡配置移入音乐中心页面）
------------------------------------------------------------------------------

local SOUNDCARD_TEMPLATE = [[
defaults.pcm.dmix.rate 44100
defaults.pcm.dmix.format S16_LE

pcm.!default {
    type plug
    slave.pcm "dmixer"
}

pcm.dmixer {
    type dmix
    ipc_key 1024
    ipc_perm 0666
    slave {
        pcm "hw:%s,0"
        period_time 0
        period_size 1024
        buffer_size 8192
        rate 44100
        format S16_LE
    }
    bindings { 0 0 1 1 }
}
ctl.dmixer {
    type hw
    card %s
}

pcm.softvol {
    type softvol
    slave.pcm "plug:dmixer"
    control {
        name "Softvol"
        card %s
    }
}
]]

function action_soundcards()
    if not guard(false) then return end
    http.header("Cache-Control", "no-store, max-age=0")
    http.prepare_content("application/json")
    local cards = safe_call(list_soundcards, {})
    local current = safe_call(resolve_soundcard, { available = false })
    local asound = fs.readfile("/etc/asound.conf") or ""
    http.write(jsonc.stringify({ ok = true, cards = cards, current = current, asound = asound }))
end

local function apply_soundcard(card, control)
    card = tostring(card or "")
    control = tostring(control or "")
    if not card:match("^%d+$") then return false, "声卡编号无效" end

    local cards = list_soundcards()
    local chosen
    for _, c in ipairs(cards) do
        if tostring(c.num) == card then chosen = c; break end
    end
    if not chosen then return false, "声卡不存在：" .. card end

    local valid = false
    for _, c in ipairs(chosen.controls) do
        if c == control then valid = true; break end
    end
    if not valid then control = chosen.controls[1] or "Master" end

    if fs.access("/etc/asound.conf") then
        sys.call("cp /etc/asound.conf /etc/asound.conf.bak >/dev/null 2>&1")
    end

    local ok, err = pcall(function()
        local f = io.open("/etc/asound.conf", "w")
        if not f then error("无法写入 /etc/asound.conf") end
        f:write(string.format(SOUNDCARD_TEMPLATE, card, card, card))
        f:close()
    end)
    if not ok then return false, tostring(err) end

    write_snd_cache(card, chosen.name, control)
    sys.call("aplay -D softvol /dev/zero -d 1 >/dev/null 2>&1")
    sys.call("(/etc/init.d/owntone restart; /etc/init.d/shairport-sync restart; /etc/init.d/gmediarender restart) >/dev/null 2>&1 &")
    return true
end

function action_soundcard()
    if not require_post() then return end
    if not guard(true) then return end
    local ok, err = apply_soundcard(
        http.formvalue("card") or "",
        http.formvalue("control") or ""
    )
    respond(ok, err)
end

local function pick_now(status)
    local order = {
        { "owntone", status.owntone },
        { "gmediarender", status.gmediarender },
        { "shairport", status.shairport },
    }

    for _, s in ipairs(order) do
        if s[2] and s[2].playing and s[2].title and s[2].title ~= "" then
            return { source = s[1], title = s[2].title, artist = s[2].artist or "" }
        end
    end
    for _, s in ipairs(order) do
        if s[2] and s[2].title and s[2].title ~= "" then
            return { source = s[1], title = s[2].title, artist = s[2].artist or "" }
        end
    end
    return { source = "none", title = "", artist = "" }
end

function action_status()
    -- 临时诊断：带 w= 参数时记录页面实测宽度
    do
        local dw = http.formvalue("w")
        if dw then
            local f = io.open("/tmp/music-diag.log", "a")
            if f then
                f:write(os.date("%H:%M:%S"),
                    " w=", tostring(dw),
                    " sw=", tostring(http.formvalue("sw") or ""),
                    " dpr=", tostring(http.formvalue("dpr") or ""), "\n")
                f:close()
            end
        end
    end
    if not guard(false) then return end

    http.header("Cache-Control", "no-store, max-age=0")
    http.prepare_content("application/json")

    if http.formvalue("soundcards") == "1" then
        local cards = safe_call(list_soundcards, {})
        local current = safe_call(resolve_soundcard, { available = false })
        http.write(jsonc.stringify({ ok = true, cards = cards, current = current }))
        return
    end

    local ip = lan_ip()
    local gmr_port = tonumber(uci_get("gmediarender", "gmediarender", "port", "49152")) or 49152

    local status = {
        ok = true,
        time = os.time(),
        hostname = sys.hostname() or "",
        physical = safe_call(resolve_soundcard, { available = false }),
        owntone = safe_call(owntone_status, { installed = false, running = false }),
        gmediarender = safe_call(gmr_status, { installed = false, running = false }, ip, gmr_port),
        shairport = safe_call(shairport_status, { installed = false, running = false }),
    }

    local auto_ok, auto_file = maybe_auto_download(status.gmediarender)
    status.gmediarender.auto_download_triggered = auto_ok
    status.gmediarender.auto_download_file = auto_file or ""
    status.now = pick_now(status)

    local running_n = 0
    local installed_n = 0
    for _, key in ipairs({ "owntone", "gmediarender", "shairport" }) do
        if status[key].running then running_n = running_n + 1 end
        if status[key].installed then installed_n = installed_n + 1 end
    end
    status.services = { total = 3, running = running_n, installed = installed_n }

    http.write(jsonc.stringify(status))
end

-------------------------------------------------------------------------------
-- 控制
-------------------------------------------------------------------------------

function action_control()
    if not require_post() then return end
    if not guard(true) then return end

    local service = http.formvalue("service") or ""
    local action = http.formvalue("action") or ""
    local value = http.formvalue("value")

    local ok, err
    if service == "owntone" then
        ok, err = owntone_control(action, value)
    elseif service == "gmediarender" then
        ok, err = gmr_control(action, value)
    elseif service == "soundcard" then
        if action == "list" then
            local cards = safe_call(list_soundcards, {})
            local current = safe_call(resolve_soundcard, { available = false })
            http.prepare_content("application/json")
            http.write(jsonc.stringify({ ok = true, cards = cards, current = current }))
            return
        end
        ok, err = apply_soundcard(
            http.formvalue("card") or "",
            http.formvalue("control") or ""
        )
    else
        ok, err = false, "未知服务: " .. tostring(service)
    end
    respond(ok, err)
end

-- GMediaRender 当前音频源“下载到设备”（原 nowplaying.htm 的功能）
function action_download()
    if not require_post() then return end
    if not guard(true) then return end

    local url = http.formvalue("url") or ""
    local title = http.formvalue("title") or ""
    local artist = http.formvalue("artist") or ""
    local cover = http.formvalue("cover") or ""

    http.prepare_content("application/json")
    if not url:match("^https?://") then
        http.write(jsonc.stringify({ ok = false, error = "无效链接" }))
        return
    end

    local ok, info = trigger_download(url, title, artist, cover)
    if ok then
        http.write(jsonc.stringify({ ok = true, file = info }))
    else
        http.write(jsonc.stringify({ ok = false, error = info }))
    end
end

-- 下载日志（原 nowplaying.htm 的下载进度条使用）
function action_download_log()
    if not guard(false) then return end
    http.header("Cache-Control", "no-store, max-age=0")
    http.prepare_content("application/json")

    local data = ""
    if fs.access("/tmp/gmediarender_dl.log") then
        local raw = fs.readfile("/tmp/gmediarender_dl.log") or ""
        local keep = {}
        for line in raw:gmatch("[^\r\n]+") do
            -- 只保留脚本自己写的进度行（带时间戳），过滤 ffmpeg / wget 的底层输出
            if line:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d ") then
                keep[#keep + 1] = (line:gsub("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d ", ""))
                if #keep > 80 then table.remove(keep, 1) end
            end
        end
        data = table.concat(keep, "\n")
        if #data > 6000 then data = data:sub(-6000) end
        data = data:gsub("\\(%d%d%d)", function(oct)
            return string.char(tonumber(oct, 8))
        end)
    end
    local progress = ""
    if fs.access("/tmp/gmr_progress.txt") then
        progress = (fs.readfile("/tmp/gmr_progress.txt") or ""):gsub("[\r\n]+", "")
    end
    http.write(jsonc.stringify({ ok = true, log = data, progress = progress }))
end

function action_volume()
    if not require_post() then return end
    if not guard(true) then return end
    local target = http.formvalue("target") or "physical"
    local action = http.formvalue("action") or "set"
    local value = tonumber(http.formvalue("value")) or 0

    local ok, err
    if target == "physical" then
        ok, err = set_physical_volume(action, value)
    elseif target == "owntone" then
        if action == "mute" or action == "unmute" then
            ok, err = owntone_mute(action)
        else
            ok, err = owntone_set_volume(value)
        end
    elseif target == "autoplay" then
        local enabled = http.formvalue("enabled")
        local value2 = (enabled == "1" or enabled == "true" or enabled == "on") and "1" or "0"
        uci:set("owntone", "owntone", "autoplay", value2)
        ok = uci:commit("owntone")
        err = (not ok) and "写入 OwnTone 自动播放设置失败" or nil
    elseif target == "gmediarender" then
        ok, err = gmr_control("volume", value)
    else
        ok, err = false, "未知音量目标: " .. tostring(target)
    end
    respond(ok, err)
end

function action_autoplay()
    if not require_post() then return end
    if not guard(true) then return end
    local enabled = http.formvalue("enabled")
    local value = (enabled == "1" or enabled == "true" or enabled == "on") and "1" or "0"
    uci:set("owntone", "owntone", "autoplay", value)
    local ok = uci:commit("owntone")
    respond(ok, (not ok) and "写入 OwnTone 自动播放设置失败" or nil)
end

function action_library()
    if not require_post() then return end
    if not guard(true) then return end
    local port = owntone_port()
    if not port then respond(false, "OwnTone 端口未知"); return end
    local shuffle = false
    local repeat_state = "off"
    local player_body = http_get(lan_ip(), port, "/api/player", 1)
    if player_body then
        local pok, pd = pcall(jsonc.parse, player_body)
        if pok and type(pd) == "table" then
            shuffle = (pd.shuffle == true)
            repeat_state = tostring(pd["repeat"] or "off")
        end
    end
    if not http_put(lan_ip(), port, "/api/queue/clear", 3) then
        respond(false, "清空播放队列失败")
        return
    end
    if not http_post(lan_ip(), port,
        "/api/queue/items/add?expression=media_kind+is+music&clear=false", 30) then
        respond(false, "加入音乐库失败")
        return
    end
    http_put(lan_ip(), port,
        "/api/player/shuffle?state=" .. (shuffle and "true" or "false"), 2)
    http_put(lan_ip(), port,
        "/api/player/repeat?state=" .. repeat_state, 2)
    local ok = http_put(lan_ip(), port, "/api/player/play", 3)
    respond(ok, (not ok) and "开始播放失败" or nil)
end

function action_monitor()
    local path = http.formvalue("path") or ""
    path = path:gsub("^file:/+", "/")
    if path == "" then
        local port = owntone_port()
        local body = http_get(lan_ip(), port, "/api/queue?id=now_playing", 1)
        if body then
            local ok, qd = pcall(jsonc.parse, body)
            if ok and type(qd) == "table" then
                local item = qd.items and qd.items[1] or qd
                if type(item) == "table" then
                    path = tostring(item.path or item.uri or ""):gsub("^file:/+", "/")
                end
            end
        end
    end
    local dirs = tostring(uci:get_first("owntone", "owntone", "directories") or "")
    local allowed = false
    for raw_d in dirs:gmatch("[^:%s]+") do
        local d = tostring(raw_d):gsub("/+$", "")
        if d ~= "" and path:sub(1, #d + 1) == d .. "/" then
            allowed = true
            break
        end
    end
    if not allowed then respond(false, "监听路径不在音乐库内"); return end

    local f = io.open(path, "rb")
    if not f then respond(false, "监听文件不存在"); return end
    local ext = path:match("%.([%w]+)$")
    ext = ext and ext:lower() or ""
    local types = {
        mp3 = "audio/mpeg", flac = "audio/flac", m4a = "audio/mp4",
        aac = "audio/aac", ogg = "audio/ogg", opus = "audio/ogg",
        wav = "audio/wav", aif = "audio/aiff", aiff = "audio/aiff",
        alac = "audio/mp4",
    }
    http.header("Content-Type", types[ext] or "application/octet-stream")
    http.header("Cache-Control", "no-store, max-age=0")
    http.header("Content-Disposition", "inline")
    local chunk
    repeat
        chunk = f:read(65536)
        if chunk then http.write(chunk) end
    until not chunk
    f:close()
end

-------------------------------------------------------------------------------
-- 服务启停
-------------------------------------------------------------------------------

local SERVICE_INIT = {
    owntone = "owntone",
    gmediarender = "gmediarender",
    shairport = "shairport-sync",
}

local SERVICE_UCI = {
    owntone = { "owntone", "owntone" },
    gmediarender = { "gmediarender", "gmediarender" },
    shairport = { "shairport-sync", "shairport-sync" },
}

local SERVICE_ACTION = {
    start = true, stop = true, restart = true, enable = true, disable = true,
}

local function service_action(name, action)
    local init_name = SERVICE_INIT[name]
    if not init_name then return false, "未知服务: " .. tostring(name) end
    if not SERVICE_ACTION[action] then return false, "未知操作: " .. tostring(action) end

    local init = "/etc/init.d/" .. init_name
    if not fs.access(init) then return false, "未安装服务: " .. init_name end

    if action == "enable" or action == "disable" then
        local cfg = SERVICE_UCI[name]
        if cfg then
            set_plugin_enabled(cfg[1], cfg[2], action == "enable" and "1" or "0")
        end
    end

    -- 放到后台，避免 restart 把 HTTP 请求卡住十几秒
    sys.call(init .. " " .. action .. " >/dev/null 2>&1 &")
    return true
end

function action_service()
    if not require_post() then return end
    if not guard(true) then return end

    local name = http.formvalue("name") or ""
    local action = http.formvalue("action") or ""

    if name == "all" then
        if action ~= "start" and action ~= "stop" and action ~= "restart" then
            respond(false, "全部操作只支持 start/stop/restart")
            return
        end
        for key in pairs(SERVICE_INIT) do
            service_action(key, action)
        end
        respond(true)
        return
    end

    local ok, err = service_action(name, action)
    respond(ok, err)
end

-------------------------------------------------------------------------------
-- 封面（AirPlay）
-------------------------------------------------------------------------------

function action_cover_fetch()
    if not require_post() then return end
    local st = safe_call(owntone_status, {}) or {}
    local path = tostring(st.path or "")
    if path == "" then respond(false, "没有正在播放的文件"); return end
    local cmd = "/usr/bin/music-cover-fetch --one " .. shq(path) .. " >/dev/null 2>&1 &"
    os.execute(cmd)
    respond(true)
end

function action_cover()
    if not guard(false) then return end

    local service = http.formvalue("service") or ""
    local path = nil
    local ctype = "image/jpeg"

    if service == "shairport" then
        path = "/tmp/shairport-cover.jpg"
        if not fs.access(path) then
            http.status(404)
            return
        end
    else
        local p = http.formvalue("path") or ""
        p = p:gsub("^file:/+", "/")
        local side, ext = cover_sidecar(p)
        if not side then
            local tmp = "/tmp/music-cover-embed"
            os.execute("rm -f " .. tmp .. ".jpg")
            os.execute("ffmpeg -y -i " .. shq(p) .. " -an -vcodec mjpeg -frames:v 1 " .. tmp .. ".jpg >/dev/null 2>&1")
            if fs.access(tmp .. ".jpg") then
                side = tmp .. ".jpg"
                ext = "jpg"
            end
        end
        if not side then
            http.status(404)
            return
        end
        path = side
        local types = { jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", webp = "image/webp" }
        ctype = types[ext] or "image/jpeg"
    end

    local data = fs.readfile(path) or ""
    if data == "" then
        http.status(404)
        return
    end
    -- AirPlay 的 PICT 可能是 JPEG 也可能是 PNG，按文件头给正确的类型
    if service == "shairport" and data:sub(1, 8) == "\137PNG\r\n\26\n" then
        ctype = "image/png"
    end
    http.header("Cache-Control", "no-store, max-age=0")
    http.prepare_content(ctype)
    http.write(data)
end
