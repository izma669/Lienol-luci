module("luci.controller.gmediarender", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/gmediarender") then return end
    entry({"admin", "services", "gmediarender"}, cbi("gmediarender"), _("GMediaRender"), 60).dependent = true
    entry({"admin", "services", "gmediarender", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "gmediarender", "nowplaying"}, call("action_nowplaying")).leaf = true
    entry({"admin", "services", "gmediarender", "control"}, call("action_control")).leaf = true
    entry({"admin", "services", "gmediarender", "download"}, call("action_download")).leaf = true
    entry({"admin", "services", "gmediarender", "download_log"}, call("action_download_log")).leaf = true
    -- 新增浏览目录接口
    entry({"admin", "services", "gmediarender", "browse"}, call("action_browse")).leaf = true
end

function action_browse()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    local path = http.formvalue("path") or "/mnt"
    if not path:match("^/mnt") then path = "/mnt" end
    if not path:match("/$") then path = path .. "/" end
    
    local dirs = {}
    if fs.access(path) then
        for name in fs.dir(path) do
            if name ~= "." and name ~= ".." then
                local fpath = path .. name
                if fs.stat(fpath, "type") == "dir" then
                    table.insert(dirs, name)
                end
            end
        end
    end
    table.sort(dirs)
    
    http.prepare_content("application/json")
    http.write_json(dirs)
end

function action_status()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    local running = sys.call("pidof gmediarender >/dev/null") == 0
    local enabled = uci:get("gmediarender", "main", "enabled")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ running = running, enabled = enabled == "1" })
end

function action_download_log()
    local fs = require "nixio.fs"
    local logfile = "/tmp/gmediarender_dl.log"
    local data = ""
    if fs.access(logfile) then
        data = fs.readfile(logfile) or ""
        if #data > 3000 then data = data:sub(-3000) end
        data = data:gsub("\\(%d%d%d)", function(oct) return string.char(tonumber(oct, 8)) end)
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ log = data })
end

local function trigger_download(url, title, artist, cover)
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    
    -- 【修复 403】解决 XML 转义导致的 URL 问题
    url = url:gsub("&amp;", "&")
    cover = (cover or ""):gsub("&amp;", "&")

    local dir = uci:get("gmediarender", "main", "download_dir")
    if not dir or dir == "" then return false, "下载路径未配置，已取消下载" end
    -- 【防爆盘保护】强制必须在 /mnt 下，且必须已存在
    if not (dir == "/mnt" or dir:match("^/mnt/")) then return false, "安全限制：下载目录必须在 /mnt 下，已取消。" end
    if not fs.access(dir) then return false, "目录不存在，已取消下载。请手动创建或重新选择：" .. dir end
    
    local function sanitize(s)
        if not s then return "" end
        s = s:gsub("[\\/:*?\"<>|]", "_")
        return s:gsub("^%s+", ""):gsub("%s+$", "")
    end
    
    local safe_title = sanitize(title)
    local safe_artist = sanitize(artist)
    if safe_title == "暂无播放" or safe_title == "空闲" then safe_title = "" end
    if safe_artist == "-" or safe_artist == "未知艺术家" then safe_artist = "" end
    
    local filename = ""
    if safe_title ~= "" and safe_artist ~= "" then filename = safe_title .. "-" .. safe_artist
    elseif safe_title ~= "" then filename = safe_title
    else filename = url:match("([^/]+)$") or "download_song" end
    
    local ext = url:gsub("%?.*$", ""):match("%.([%a%d]+)$")
    if not ext or #ext > 4 then ext = "mp3" end
    if not filename:match("%.%w+$") then filename = filename .. "." .. ext end
    
    local filepath = dir .. "/" .. filename
    local logfile = "/tmp/gmediarender_dl.log"
    
    local function shq(s)
        return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
    end
    
    -- 下载 + 封面检测/嵌入统一交给脚本处理（脚本自行读取 download_cover / cover_skip_existing）
    local cmd = string.format("( %s %s %s %s %s >/dev/null 2>&1 & )",
        "/usr/libexec/gmediarender-dl.sh",
        shq(url), shq(filepath), shq(cover or ""), shq(logfile))
    sys.call(cmd)
    return true, "已开始后台下载:\n" .. filename
end

function action_download()
    local http = require "luci.http"
    local url = http.formvalue("url")
    local title = http.formvalue("title") or ""
    local artist = http.formvalue("artist") or ""
    local cover = http.formvalue("cover") or ""
    if not url or url == "" or not url:match("^https?://") then
        http.prepare_content("application/json"); http.write_json({success = false, msg = "无效链接"}); return
    end
    local ok, msg = trigger_download(url, title, artist, cover)
    http.prepare_content("application/json"); http.write_json({success = ok, msg = msg})
end

local function get_host_ip()
    local uci = require "luci.model.uci".cursor()
    local iface = uci:get("gmediarender", "main", "interface") or "br-lan"
    -- 如果填的就是 IP，直接用
    if iface:match("^%d+%.%d+%.%d+%.%d+$") then return iface end

    local sys = require "luci.sys"
    -- 网卡名（如 br-lan）→ 从 ip 命令取 IPv4
    local out = sys.exec("ip -4 -o addr show dev " .. iface .. " 2>/dev/null") or ""
    local ip = out:match("inet%s+(%d+%.%d+%.%d+%.%d+)")
    if ip and ip ~= "" then return ip end

    -- 逻辑接口名（如 lan）→ 从 ubus 取
    local u2 = sys.exec("ubus call network.interface." .. iface .. " status 2>/dev/null") or ""
    ip = u2:match('"address"%s*:%s*"(%d+%.%d+%.%d+%.%d+)"')
    if ip and ip ~= "" then return ip end

    local ip2 = uci:get("network", "lan", "ipaddr")
    if ip2 and ip2 ~= "" then return ip2 end
    return "127.0.0.1"
end

local function upnp_request(host, port, action, body_inner)
    local nixio = require "nixio"
    local service_type = "urn:schemas-upnp-org:service:AVTransport:1"
    local control_url = "/upnp/control/rendertransport1"
    
    if action == "GetVolume" or action == "SetVolume" then
        service_type = "urn:schemas-upnp-org:service:RenderingControl:1"
        control_url = "/upnp/control/rendercontrol1"
    end
    
    local soap_body = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:%s xmlns:u="%s">%s</u:%s></s:Body>
</s:Envelope>]], action, service_type, body_inner, action)

    local http_req = string.format(
        "POST %s HTTP/1.1\r\n" ..
        "Host: %s:%d\r\n" ..
        "Content-Type: text/xml; charset=\"utf-8\"\r\n" ..
        "SOAPAction: \"%s#%s\"\r\n" ..
        "Content-Length: %d\r\n" ..
        "Connection: close\r\n\r\n%s",
        control_url, host, port, service_type, action, #soap_body, soap_body
    )

    local sock = nixio.socket("inet", "stream")
    pcall(function() sock:setopt("socket", "rcvtimeo", 1000) end)
    pcall(function() sock:setopt("socket", "sndtimeo", 1000) end)
    
    if not sock:connect(host, port) then sock:close() return nil end
    if not sock:send(http_req) then sock:close() return nil end
    
    local response = ""
    while true do
        local data = sock:recv(4096)
        if not data then break end
        response = response .. data
        if response:find("</s:Envelope>") then break end
    end
    sock:close()
    
    if response == "" then return nil end
    return response
end

function action_control()
    local http = require "luci.http"
    local uci = require "luci.model.uci".cursor()
    local host = get_host_ip()
    local port = tonumber(uci:get("gmediarender", "main", "port")) or 49152
    
    local act = http.formvalue("action")
    local val = http.formvalue("value")
    local instance = "<InstanceID>0</InstanceID>"
    local res = nil
    
    if act == "play" then
        res = upnp_request(host, port, "Play", instance .. "<Speed>1</Speed>")
    elseif act == "pause" then
        res = upnp_request(host, port, "Pause", instance)
    elseif act == "stop" then
        res = upnp_request(host, port, "Stop", instance)
    elseif act == "next" then
        res = upnp_request(host, port, "Next", instance)
    elseif act == "previous" then
        res = upnp_request(host, port, "Previous", instance)
    elseif act == "seek" and val then
        local t = tostring(val)
        -- 允许 HH:MM:SS 和 MM:SS 两种写法
        if not (t:match("^%d+:%d%d:%d%d$") or t:match("^%d%d:%d%d$")) then
            http.prepare_content("application/json")
            http.write_json({ success = false, error = "时间格式应为 HH:MM:SS" })
            return
        end
        res = upnp_request(host, port, "Seek", instance .. "<Unit>REL_TIME</Unit><Target>" .. t .. "</Target>")
    elseif act == "volume" and val then
        local v_num = tonumber(val)
        if not v_num then
            http.prepare_content("application/json")
            http.write_json({ success = false, error = "音量值无效" })
            return
        end
        v_num = math.max(0, math.min(100, math.floor(v_num)))
        res = upnp_request(host, port, "SetVolume", instance .. "<Channel>Master</Channel><DesiredVolume>" .. v_num .. "</DesiredVolume>")
    end
    
    -- 设备返回 SOAP Fault 时也算失败（以前只要收到响应就报成功）
    local ok = false
    if res then
        ok = not (res:find("<s:Fault", 1, true) or res:find("<UPnPError", 1, true))
    end
    http.prepare_content("application/json")
    http.write_json({ success = ok })
end

function action_nowplaying()
    local uci = require "luci.model.uci".cursor()
    local fs  = require "nixio.fs"
    
    local info = {
        playing=false, position="", duration="", title="", artist="", album="", albumart="",
        streamurl="", format="", quality="", volume="0", mediatype="", debug="", soundcard="",
        auto_download_triggered=false
    }

    local host = get_host_ip()
    local port = tonumber(uci:get("gmediarender", "main", "port")) or 49152
    local instance = "<InstanceID>0</InstanceID>"

    local pos_resp = upnp_request(host, port, "GetPositionInfo", instance)
    if pos_resp then
        info.position = pos_resp:match("<RelTime>([^<]+)</RelTime>") or pos_resp:match("<[^>]*RelTime[^>]*>([^<]+)</[^>]*RelTime>") or ""
        info.duration = pos_resp:match("<TrackDuration>([^<]+)</TrackDuration>") or pos_resp:match("<[^>]*TrackDuration[^>]*>([^<]+)</[^>]*TrackDuration>") or ""
        
        local meta = pos_resp:match("<TrackMetaData>([^<]+)</TrackMetaData>") or pos_resp:match("<[^>]*TrackMetaData[^>]*>([^<]+)</[^>]*TrackMetaData>")
        if meta and meta ~= "" then
            meta = meta:gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&amp;","&")
            
            info.title    = meta:match("<dc:title>([^<]+)</dc:title>") or ""
            info.artist   = meta:match("<upnp:artist>([^<]+)</upnp:artist>") or ""
            info.album    = meta:match("<upnp:album>([^<]+)</upnp:album>") or ""
            info.albumart = meta:match("<upnp:albumArtURI>([^<]+)</upnp:albumArtURI>") or ""

            info.streamurl = meta:match("<res[^>]*>([^<]+)</res>") or ""
            if info.streamurl == "" then info.streamurl = pos_resp:match("<TrackURI>([^<]+)</TrackURI>") or "" end

            -- 封面地址可能是相对路径，用流地址的 scheme://host 补全
            if info.albumart ~= "" and not info.albumart:match("^https?://") then
                local base = info.streamurl:match("^(https?://[^/]+)")
                if base then
                    info.albumart = base .. "/" .. info.albumart:gsub("^/+", "")
                else
                    info.albumart = ""
                end
            end

            local cls = meta:match("<upnp:class>([^<]+)</upnp:class>")
            if cls then
                if cls:match("musicTrack") then info.mediatype = "歌曲"
                elseif cls:match("audioBroadcast") then info.mediatype = "电台"
                elseif cls:match("audioItem") then info.mediatype = "音频" end
            end
            
            local mime = meta:match("protocolInfo=\"[^\"]*:(audio/[^:;]+)")
            if mime then
                if mime:match("mpeg") then info.format = "MP3"
                elseif mime:match("flac") then info.format = "FLAC"
                elseif mime:match("mp4") or mime:match("m4a") then info.format = "M4A/AAC"
                elseif mime:match("wav") then info.format = "WAV"
                elseif mime:match("ogg") then info.format = "OGG"
                elseif mime:match("opus") then info.format = "OPUS"
                else info.format = mime end
            end
        end
    end

    local trans_resp = upnp_request(host, port, "GetTransportInfo", instance)
    if trans_resp then
        local state = trans_resp:match("<CurrentTransportState>([^<]+)</CurrentTransportState>")
        if state == "PLAYING" then info.playing = true end
    end

    local vol_resp = upnp_request(host, port, "GetVolume", instance .. "<Channel>Master</Channel>")
    if vol_resp then
        local vol = vol_resp:match("<CurrentVolume>([^<]+)</CurrentVolume>")
        if vol then info.volume = vol end
    end

    -- 额外元数据：编码 / 来源 / 下一首 / 流派 / 年份 / 码率 / 采样率 / 声道
    info.codec, info.source_host, info.next_title = "", "", ""
    info.genre, info.year, info.bitrate, info.samplerate, info.channels = "", "", "", "", ""
    local mi_resp = upnp_request(host, port, "GetMediaInfo", instance)
    if mi_resp then
        local didl = mi_resp:match("<CurrentURIMetaData>([^<]*)</CurrentURIMetaData>") or ""
        if didl ~= "" then
            didl = didl:gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&amp;","&")
            info.genre   = didl:match("<upnp:genre>([^<]*)</upnp:genre>") or ""
            local date   = didl:match("<dc:date>([^<]*)</dc:date>") or ""
            info.year    = date:match("^(%d%d%d%d)") or ""
            local res_tag = didl:match("<res[^>]*>") or ""
            info.bitrate    = res_tag:match('bitrate="(%d+)"') or ""
            info.samplerate = res_tag:match('sampleFrequency="(%d+)"') or ""
            info.channels   = res_tag:match('nrAudioChannels="(%d+)"') or ""
            local proto = res_tag:match('protocolInfo="([^"]*)"') or ""
            local pn = proto:match("DLNA%.ORG_PN=([^;:]*)")
            local mime = proto:match(":(audio/[^:;]+)")
            info.codec = (pn and pn ~= "") and pn or (mime or "")
            if info.streamurl == "" then
                info.streamurl = didl:match("<res[^>]*>([^<]+)</res>") or ""
            end
        end
        local next_uri = mi_resp:match("<NextURI>([^<]*)</NextURI>") or ""
        local next_meta = mi_resp:match("<NextURIMetaData>([^<]*)</NextURIMetaData>") or ""
        if next_meta ~= "" then
            local nm = next_meta:gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&amp;","&")
            info.next_title = nm:match("<dc:title>([^<]*)</dc:title>") or ""
        end
        if info.next_title == "" and next_uri ~= "" then
            info.next_title = next_uri:match("([^/]+)$") or ""
        end
    end
    info.source_host = info.streamurl:match("^https?://([^/:]+)") or ""

    local sys = require "luci.sys"
    local ps_out = sys.exec("ps w | grep gmediarender | grep -v grep")
    local out_arg = ps_out:match("%-o%s+([%w:%,%-]+)") or ps_out:match("%-d%s+([%w:%,%-]+)")
    local soundcard = out_arg
    if not soundcard or soundcard == "" then
        local proc_cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
        if proc_cards and proc_cards ~= "" then
            local card_num, card_name = proc_cards:match("(%d+) %[.-%]:.-%-%s+([^\n]+)")
            if card_num and card_name then soundcard = "hw:" .. card_num .. " (" .. card_name .. ")" end
        end
    end
    if not soundcard or soundcard == "" then soundcard = "-" end
    info.soundcard = soundcard:gsub("%s+", " ")

    local auto_dl = uci:get("gmediarender", "main", "auto_download")
    if auto_dl == "1" then
        if info.playing and info.streamurl and info.streamurl:match("^https?://") then
            local last_dl_file = "/tmp/gmediarender_last_dl.txt"
            local last_url = ""
            if fs.access(last_dl_file) then last_url = fs.readfile(last_dl_file) or "" end
            last_url = last_url:gsub("%s+$", "")
            
            if info.streamurl ~= last_url then
                fs.writefile(last_dl_file, info.streamurl)
                local ok, msg = trigger_download(info.streamurl, info.title, info.artist, info.albumart)
                if ok then info.auto_download_triggered = true end
            end
        end
    end

    -- 下载/嵌入状态（由 /usr/libexec/gmediarender-dl.sh 写入）
    local dl_state, dl_file = "", ""
    if fs.access("/tmp/gmr_dl_state") then
        local stt = fs.stat("/tmp/gmr_dl_state")
        local age = os.time() - (tonumber(stt and stt.mtime) or 0)
        local raw = fs.readfile("/tmp/gmr_dl_state") or ""
        local s, f = raw:match("^(%a+)|(.-)%s*$")
        if s and age >= 0 and age < 300 then
            dl_state = s
            dl_file = f or ""
        end
    end
    info.dl_state = dl_state
    info.dl_file = dl_file

    -- 最近一次结果（跳过/完成/失败），60 秒内有效
    local dl_result, dl_result_file = "", ""
    if fs.access("/tmp/gmr_dl_result") then
        local raw = fs.readfile("/tmp/gmr_dl_result") or ""
        local tp, fn, ts = raw:match("^(%a+)|(.-)|(%d+)")
        if tp and ts and (os.time() - tonumber(ts)) <= 60 then
            dl_result = tp
            dl_result_file = fn or ""
        end
    end
    info.dl_result = dl_result
    info.dl_result_file = dl_result_file

    luci.http.prepare_content("application/json")
    luci.http.write_json(info)
end
