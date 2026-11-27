-- GMediaRender 子页面：正在播放 / 封面下载 / 歌词下载 / 日志查看
module("luci.controller.gmediarender_extra", package.seeall)

local SERVER_NAME = {
    lrclib = "LRCLIB",
    kuwo = "酷我",
    netease = "网易云",
    custom = "自定义",
}

function index()
    entry({"admin", "services", "gmediarender", "playing"},
          template("gmediarender/playing"), _("正在播放"), 0).dependent = true

    entry({"admin", "services", "gmediarender", "cover"},
          cbi("gmediarender_cover"), _("封面下载"), 60).dependent = true

    entry({"admin", "services", "gmediarender", "lyrics"},
          cbi("gmediarender_lyrics"), _("歌词下载"), 61).dependent = true

    entry({"admin", "services", "gmediarender", "logs"},
          template("gmediarender/logs"), _("日志查看"), 62).dependent = true

    entry({"admin", "services", "gmediarender", "lyric_state"},
          call("action_lyric_state")).leaf = true
end

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function uci_get(k, d)
    local f = io.popen("uci -q get gmediarender.main." .. k .. " 2>/dev/null")
    if not f then return d end
    local v = f:read("*a") or ""
    f:close()
    v = v:gsub("%s+$", "")
    if v == "" then return d end
    return v
end

local function lyric_servers()
    local out = {}
    local f = io.popen("uci -q get gmediarender.main.lyric_servers 2>/dev/null")
    if f then
        local v = f:read("*a") or ""
        f:close()
        for w in v:gmatch("%S+") do
            out[#out + 1] = SERVER_NAME[w] or w
        end
    end
    if #out == 0 then out = { "LRCLIB", "酷我", "网易云" } end
    return table.concat(out, "/")
end

-- 当前歌曲的歌词状态：等待下载 / 等待匹配 / 未找到 / 已内嵌 / 已存 .lrc
function action_lyric_state()
    local http = require "luci.http"
    local fs = require "nixio.fs"

    local title = http.formvalue("title") or ""
    local artist = http.formvalue("artist") or ""
    local dir = uci_get("download_dir", "/mnt/mmcblk0p1/music")

    local function sanitize(s)
        s = tostring(s or ""):gsub("[\\/:*?\"<>|]", "_")
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function esc(s)
        s = tostring(s or "")
        return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
    end

    local text, color

    if title == "" or title == "暂无播放" then
        text, color = "ℹ 等待播放", "#888"
    else
        local base = sanitize(title)
        local a = sanitize(artist)
        if a ~= "" and a ~= "-" and a ~= "未知艺术家" then
            base = base .. "-" .. a
        end

        local path = nil
        for _, ext in ipairs({ "mp3", "flac", "m4a", "ogg", "wav", "ape", "aac", "MP3", "FLAC" }) do
            local p = dir .. "/" .. base .. "." .. ext
            if fs.access(p) then path = p break end
        end

        local servers = lyric_servers()

        if not path then
            text, color = "ℹ 歌词等待歌曲下载（源 " .. servers .. "）", "#888"
        else
            -- 是否已内嵌（30 秒缓存）
            local cache = "/tmp/gmr-lyric-state.cache"
            local st = nil
            if fs.access(cache) then
                local c = fs.readfile(cache) or ""
                local p, tm, s = c:match("^(.-)|(%d+)|(%a+)$")
                if p == path and tm and (os.time() - tonumber(tm)) < 10 then st = s end
            end
            if not st then
                local ok = false
                local pf = io.popen("ffprobe -v error -show_entries format_tags=lyrics -show_entries stream_tags=lyrics -of default=nw=1 " .. shq(path) .. " 2>/dev/null")
                if pf then
                    local o = pf:read("*a") or ""
                    pf:close()
                    ok = o:lower():find("lyrics=") ~= nil
                end
                st = ok and "embed" or "none"
                fs.writefile(cache, path .. "|" .. os.time() .. "|" .. st)
            end

            -- 该文件最近一条歌词日志
            local lf = io.popen("grep -F " .. shq(base) .. " /tmp/gmediarender-lyric.log 2>/dev/null | tail -n 1")
            local line = ""
            if lf then line = lf:read("*a") or ""; lf:close() end

            local src = line:match("^OK%s+(%S+)%s+|")
            local srcname = src and (SERVER_NAME[src] or src) or ""

            if st ~= "embed" and line:find("^OK") and line:find("写入 embed") then
                st = "embed"
            end
            if st == "embed" then
                -- 只要日志里出现过这首歌的 OK（写入 embed），就按“已嵌入”显示；
                -- 守护进程随后写的 SKIP 只是“已存在歌词”的扫描记录，不能覆盖它
                local okl = io.popen("grep -F " .. shq(base) .. " /tmp/gmediarender-lyric.log 2>/dev/null | grep '^OK' | tail -n 1")
                local oklast = ""
                if okl then oklast = okl:read("*a") or ""; okl:close() end
                local ok_src = oklast:match("^OK%s+(%S+)%s+|")
                if ok_src then srcname = SERVER_NAME[ok_src] or ok_src end

                text = "✅ 已嵌入歌词"
                if srcname ~= "" then text = text .. "（源 " .. srcname .. "）" end
                text = text .. "，保存至 " .. path
                color = "#0a8f2c"
            elseif fs.access((path:gsub("%.[%w]+$", "")) .. ".lrc") then
                local lrcpath = (path:gsub("%.[%w]+$", "")) .. ".lrc"
                text = "✅ 已保存歌词文件"
                if srcname ~= "" then text = text .. "（源 " .. srcname .. "）" end
                text = text .. "，保存至 " .. lrcpath
                color = "#0a8f2c"
            elseif line:find("^SKIP") then
                text, color = "ℹ 文件已内嵌合适的歌词，跳过嵌入", "#888"
            elseif line:find("^MISS") then
                text, color = "⚠ 未找到歌词（已试 " .. servers .. "）", "#d9534f"
            elseif line:find("^OK") then
                text = "⏳ 正在写入歌词"
                if srcname ~= "" then text = text .. "（源 " .. srcname .. "）" end
                color = "#e67e22"
            else
                text, color = "⏳ 歌词匹配中（源 " .. servers .. "）", "#e67e22"
            end
        end
    end

    http.prepare_content("application/json")
    http.write(string.format('{"text":"%s","color":"%s"}', esc(text), color))
end