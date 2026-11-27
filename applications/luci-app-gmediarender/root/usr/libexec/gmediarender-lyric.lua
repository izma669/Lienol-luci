#!/usr/bin/lua
-- GMediaRender 歌词工具（合并版）
--   gmediarender-lyric.lua <音频文件>     取歌词并写入音频标签
--   gmediarender-lyric.lua --fetch <文件> 只输出歌词（供下载脚本一次写入）
--   gmediarender-lyric.lua --scan         扫描下载目录，给缺少歌词的文件补写

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function uci(opt, default)
    local f = io.popen("uci -q get gmediarender.main." .. opt .. " 2>/dev/null")
    if not f then return default end
    local v = f:read("*a") or ""
    f:close()
    v = v:gsub("%s+$", "")
    if v == "" then return default end
    return v
end

local function uci_list(opt)
    local out = {}
    local f = io.popen("uci -q get gmediarender.main." .. opt .. " 2>/dev/null")
    if not f then return out end
    local v = f:read("*a") or ""
    f:close()
    for w in v:gmatch("%S+") do out[#out + 1] = w end
    return out
end

local function urlenc(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- ---------- 极简 JSON ----------
local json = {}
do
    local pos, str
    local function skip()
        while true do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
        end
    end
    local parse_string
    local function parse_value()
        skip()
        local c = str:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skip()
            if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                skip()
                local k = parse_string()
                skip(); pos = pos + 1
                obj[k] = parse_value()
                skip()
                local d = str:sub(pos, pos); pos = pos + 1
                if d == "}" then break end
            end
            return obj
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skip()
            if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parse_value()
                skip()
                local d = str:sub(pos, pos); pos = pos + 1
                if d == "]" then break end
            end
            return arr
        elseif c == '"' then
            return parse_string()
        elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else
            local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if num and #num > 0 then pos = pos + #num; return tonumber(num) end
            pos = pos + 1
            return nil
        end
    end
    parse_string = function()
        pos = pos + 1
        local buf = {}
        while true do
            local c = str:sub(pos, pos)
            if c == "" then break end
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local n = str:sub(pos + 1, pos + 1)
                if n == "n" then buf[#buf + 1] = "\n"; pos = pos + 2
                elseif n == "t" then buf[#buf + 1] = "\t"; pos = pos + 2
                elseif n == "r" then buf[#buf + 1] = "\r"; pos = pos + 2
                elseif n == "u" then
                    local cp = tonumber(str:sub(pos + 2, pos + 5), 16) or 63
                    if cp < 128 then buf[#buf + 1] = string.char(cp)
                    elseif cp < 2048 then
                        buf[#buf + 1] = string.char(192 + math.floor(cp / 64), 128 + cp % 64)
                    else
                        buf[#buf + 1] = string.char(224 + math.floor(cp / 4096),
                            128 + math.floor(cp / 64) % 64, 128 + cp % 64)
                    end
                    pos = pos + 6
                else buf[#buf + 1] = n; pos = pos + 2 end
            else
                buf[#buf + 1] = c; pos = pos + 1
            end
        end
        return table.concat(buf)
    end
    function json.decode(s)
        str = s; pos = 1
        local ok, v = pcall(parse_value)
        if not ok then return nil end
        return v
    end
end

local function fetch(url)
    local f = io.popen("curl -fsSL --connect-timeout 8 --max-time 20 " .. shq(url) .. " 2>/dev/null")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    if not body or #body < 2 then return nil end
    return body
end

local function is_lrc(s)
    return type(s) == "string" and #s >= 8 and s:find("%[%d%d:%d%d") ~= nil
end

local function lrclist_to_lrc(list)
    local out = {}
    for _, it in ipairs(list or {}) do
        local t = tonumber(it.time) or 0
        out[#out + 1] = string.format("[%02d:%05.2f]%s", math.floor(t / 60), t - math.floor(t / 60) * 60,
            tostring(it.lineLyric or ""))
    end
    return table.concat(out, "\n")
end

local SOURCES = {}

SOURCES.lrclib = function(title, artist)
    local body = fetch("https://lrclib.net/api/search?track_name=" .. urlenc(title) .. "&artist_name=" .. urlenc(artist))
    if not body then return nil end
    local d = json.decode(body)
    if type(d) ~= "table" then return nil end
    local list = {}
    for _, it in ipairs(d) do
        if type(it) == "table" then
            local lrc = it.syncedLyrics or it.plainLyrics
            if is_lrc(lrc) then
                list[#list + 1] = { dur = tonumber(it.duration), lrc = lrc,
                                    name = tostring(it.trackName or "") .. " / " .. tostring(it.artistName or "") }
            end
        end
    end
    return list
end

SOURCES.kuwo = function(title, artist)
    local body = fetch("http://search.kuwo.cn/r.s?all=" .. urlenc(title .. " " .. artist) ..
        "&ft=music&itemset=web_2013&client=kt&pn=0&rn=8&rformat=json&encoding=utf8")
    if not body then return nil end
    local ids, durs = {}, {}
    for rid, dur in body:gmatch("'MUSICRID':%s*'MUSIC_(%d+)'(.-)'DURATION':%s*'(%d+)'") do
        ids[#ids + 1] = rid; durs[#durs + 1] = tonumber(dur)
    end
    if #ids == 0 then
        for rid in body:gmatch("'MUSICRID':%s*'MUSIC_(%d+)'") do ids[#ids + 1] = rid end
    end
    local list = {}
    for i, rid in ipairs(ids) do
        if i > 4 then break end
        local b2 = fetch("http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=" .. rid)
        if b2 then
            local d = json.decode(b2)
            if type(d) == "table" and type(d.data) == "table" then
                local lrc = lrclist_to_lrc(d.data.lrclist)
                if is_lrc(lrc) then list[#list + 1] = { dur = durs[i], lrc = lrc, name = "kuwo:" .. rid } end
            end
        end
    end
    return list
end

SOURCES.netease = function(title, artist)
    local body = fetch("http://music.163.com/api/search/get/web?s=" .. urlenc(title .. " " .. artist) .. "&type=1&limit=8")
    if not body then return nil end
    local d = json.decode(body)
    if type(d) ~= "table" or type(d.result) ~= "table" or type(d.result.songs) ~= "table" then return nil end
    local list = {}
    for i, song in ipairs(d.result.songs) do
        if i > 4 then break end
        if song.id then
            local b2 = fetch("http://music.163.com/api/song/lyric?id=" .. song.id .. "&lv=1&kv=1&tv=-1")
            if b2 then
                local d2 = json.decode(b2)
                local lrc = d2 and d2.lrc and d2.lrc.lyric
                if is_lrc(lrc) then
                    list[#list + 1] = { dur = song.duration and (tonumber(song.duration) / 1000) or nil,
                                        lrc = lrc, name = tostring(song.name or "") .. " #" .. tostring(song.id) }
                end
            end
        end
    end
    return list
end

local function custom_list(tpl, title, artist)
    if not tpl or tpl == "" then return nil end
    local url = tpl:gsub("{title}", function() return urlenc(title) end)
                     :gsub("{artist}", function() return urlenc(artist) end)
                     :gsub("{title_raw}", function() return title end)
                     :gsub("{artist_raw}", function() return artist end)
    local body = fetch(url)
    if not body then return nil end
    if body:sub(1, 1) == "{" or body:sub(1, 1) == "[" then
        local d = json.decode(body)
        if type(d) == "table" then
            for _, k in ipairs({ "lrc", "lyric", "lyrics", "syncedLyrics", "plainLyrics" }) do
                if is_lrc(d[k]) then return { { lrc = d[k], name = "custom" } } end
            end
            if type(d.data) == "table" and is_lrc(d.data.lrc) then
                return { { lrc = d.data.lrc, name = "custom" } }
            end
        end
        return nil
    end
    if is_lrc(body) then return { { lrc = body, name = "custom" } } end
    return nil
end

-- ---------- 工具 ----------
local function probe_duration(file)
    local f = io.popen("ffprobe -v error -show_entries format=duration -of csv=p=0 " .. shq(file) .. " 2>/dev/null")
    if not f then return nil end
    local n = tonumber((f:read("*a") or ""):match("([%d%.]+)"))
    f:close()
    if n and n > 1 then return n end
    return nil
end

local function has_lyrics(file)
    local f = io.popen("ffprobe -v error -show_entries format_tags=lyrics -show_entries stream_tags=lyrics -of default=nw=1 " .. shq(file) .. " 2>/dev/null")
    if not f then return false end
    local v = f:read("*a") or ""
    f:close()
    return v:lower():find("lyrics=") ~= nil
end

local function have_ffmpeg()
    return os.execute("ffprobe -version >/dev/null 2>&1") == 0
       and os.execute("ffmpeg -version >/dev/null 2>&1") == 0
end

local function logline(msg)
    local lf = io.open("/tmp/gmediarender-lyric.log", "a")
    if lf then lf:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n"); lf:close() end
end

local function split_name(path)
    local base = path:gsub("^.*/", ""):gsub("%.[%w]+$", "")
    local title, artist = base, ""
    local i = base:match("^.*()%-")
    if i and i > 1 then title, artist = base:sub(1, i - 1), base:sub(i + 1) end
    return (title:gsub("^%s+", ""):gsub("%s+$", "")), (artist:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find_lrc(title, artist)
    local tol = tonumber(uci("lyric_tolerance", "8")) or 8
    local target = probe_duration(arg_path_cached or "")
    local candidates = {}

    local servers = uci_list("lyric_servers")
    if #servers == 0 then servers = { "lrclib", "kuwo", "netease" } end

    local order = uci("lyric_order", "")
    if order ~= "" then
        local seen, ordered = {}, {}
        for name in order:gmatch("[^,%s]+") do
            for _, s in ipairs(servers) do
                if s == name and not seen[s] then seen[s] = true; ordered[#ordered + 1] = s end
            end
        end
        for _, s in ipairs(servers) do if not seen[s] then ordered[#ordered + 1] = s end end
        servers = ordered
    end

    for _, s in ipairs(servers) do
        local fn = SOURCES[s]
        if fn then
            local ok, list = pcall(fn, title, artist)
            if ok and list then
                for _, c in ipairs(list) do c.source = s; candidates[#candidates + 1] = c end
            end
        end
    end
    for _, tpl in ipairs(uci_list("lyric_custom")) do
        local ok, list = pcall(custom_list, tpl, title, artist)
        if ok and list then
            for _, c in ipairs(list) do c.source = "custom"; candidates[#candidates + 1] = c end
        end
    end

    if #candidates == 0 then return nil end

    local best, bestdiff
    for _, c in ipairs(candidates) do
        local diff
        if target and c.dur then diff = math.abs(c.dur - target)
        elseif target then diff = (tonumber(uci("lyric_tolerance", "8")) or 8) + 1
        else diff = 0 end
        if not bestdiff or diff < bestdiff then best, bestdiff = c, diff end
    end
    if target and best and best.dur and bestdiff > math.max(tol * 4, 30) then return nil end
    return best, target, bestdiff
end

-- 处理单个文件；“fetch” 模式只返回歌词文本
function process(path, fetch_only)
    local title, artist = split_name(path)
    arg_path_cached = path
    local best, target, bestdiff = find_lrc(title, artist)
    if not best then
        logline("MISS " .. path:gsub("^.*/", ""))
        return nil
    end
    if fetch_only then
        local src = best.source or ""
        logline(string.format("OK %s | %s | 下载流程内嵌", src, path:gsub("^.*/", ""):gsub("%.[%w]+$", "")))
        return best.lrc
    end
    local mode = uci("lyric_mode", "embed")
    local lrcpath = (path:gsub("%.[%w]+$", "")) .. ".lrc"
    local did = false

    if mode == "lrc" or mode == "both" then
        local lf = io.open(lrcpath, "w")
        if lf then
            lf:write(best.lrc)
            if not best.lrc:find("\n$") then lf:write("\n") end
            lf:close()
            did = true
        end
        if mode == "lrc" then
            logline(string.format("OK %s | %s | 写入 lrc", best.source or "", path:gsub("^.*/", "")))
            return best.lrc
        end
    end

    if not have_ffmpeg() then
        if did then return best.lrc end
        return nil
    end
    if has_lyrics(path) then
        logline("SKIP 已有歌词标签 " .. path:gsub("^.*/", ""))
        if did then return best.lrc end
        return nil
    end
    local ext = (path:match("%.([%w]+)$") or ""):lower()
    local tmp = path .. ".lyr.tmp." .. ext
    local key = (ext == "flac" or ext == "ogg") and "LYRICS" or "lyrics"
    local cmd = string.format("ffmpeg -v error -y -i %s -map 0 -c copy -metadata %s=%s %s %s 2>/dev/null",
        shq(path), key, shq(best.lrc), (ext == "mp3" and "-id3v2_version 3" or ""), shq(tmp))
    if os.execute(cmd) == 0 then
        local f = io.open(tmp, "rb")
        if f then
            local sz = f:seek("end"); f:close()
            if sz and sz > 1024 then
                os.remove(path); os.rename(tmp, path)
                logline(string.format("OK %s | %s | 写入 embed", best.source or "", path:gsub("^.*/", "")))
                return best.lrc
            end
        end
        os.remove(tmp)
    end
    return nil
end

-- ---------- 入口 ----------
local mode = arg[1]
local dir_opt = uci("download_dir", "")
local dl_dir = dir_opt ~= "" and dir_opt or "/mnt/mmcblk0p1/music"

if mode == "--scan" then
    local f = io.popen("ls -1 " .. shq(dl_dir) .. " 2>/dev/null")
    if not f then os.exit(0) end
    local n = 0
    for name in f:lines() do
        if name:match("%.[mM][pP]3$") or name:match("%.[fF][lL][aA][cC]$") or name:match("%.[mM]4[aA]$") then
            local p = dl_dir .. "/" .. name
            if not has_lyrics(p) then
                if process(p, false) then n = n + 1 end
                if n >= 10 then break end
            end
        end
    end
    f:close()
    os.exit(0)
end

if mode == "--fetch" then
    local p = arg[2]
    if not p or p == "" then os.exit(1) end
    local lrc = process(p, true)
    if not lrc then os.exit(1) end
    io.write(lrc)
    if not lrc:find("\n$") then io.write("\n") end
    os.exit(0)
end

if mode and mode ~= "" then
    process(mode, false)
    os.exit(0)
end
os.exit(1)