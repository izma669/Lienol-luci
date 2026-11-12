module("luci.controller.media-center", package.seeall)

function index()
    entry({"admin", "services", "media-center"}, template("media-center/overview"), _("媒体中心"), 30).leaf = true

    entry({"dlna", "ping"}, call("dlna_ping")).leaf = true
    entry({"dlna", "discover"}, call("dlna_discover")).leaf = true
    entry({"dlna", "cast"}, call("dlna_cast")).leaf = true
    entry({"dlna", "probe"}, call("dlna_probe")).leaf = true
    entry({"dlna", "cover"}, call("dlna_cover")).leaf = true
    entry({"dlna", "control"}, call("dlna_control")).leaf = true
    entry({"dlna", "get_position"}, call("dlna_get_position")).leaf = true
    entry({"dlna", "lyrics"}, call("dlna_lyrics")).leaf = true
    entry({"dlna", "save_lyrics"}, post("dlna_save_lyrics")).leaf = true
    entry({"dlna", "caster"}, call("dlna_caster")).leaf = true

    entry({"dlna", "ffprobe"}, post("dlna_ffprobe")).leaf = true
    entry({"dlna", "subtitle"}, call("dlna_subtitle")).leaf = true
    entry({"dlna", "image"}, call("dlna_image")).leaf = true
    entry({"dlna", "extract_audio"}, post("dlna_extract_audio")).leaf = true
    entry({"dlna", "get_progress"}, call("dlna_get_progress")).leaf = true
    entry({"dlna", "cancel_extract"}, post("dlna_cancel_extract")).leaf = true
    entry({"dlna", "check_task"}, post("dlna_check_task")).leaf = true
    entry({"dlna", "list_dir"}, call("dlna_list_dir")).leaf = true
    entry({"dlna", "tasks"}, call("dlna_tasks")).leaf = true
end

-------------------------------------------------------------------------------
-- 路径处理
--
-- 历史问题：下面所有接口都把 "/mnt" 写死成媒体根目录。旧机器 U 盘挂在 /mnt，
-- 所以能用；换到 x86 后盘挂在 /mnt/sda1，uhttpd 的 home 改了，Lua 没改，
-- 于是 /media/xxx.mkv 被解析成 /mnt/media/xxx.mkv，必然“文件不存在”。
--
-- 现在改为自动解析根目录，顺序：
--   1) UCI: /etc/config/media-center 里 config media 'media' / option root '/mnt/sda1'
--   2) /proc/mounts 中所有 /mnt/* 挂载点
--   3) /mnt 下实际存在的子目录
--   4) /mnt 兜底
-- 只要某个根目录下该文件真实存在就采用它，所以换盘、换挂载点都不用再改代码。
-------------------------------------------------------------------------------

local function unescape_file(s)
    return (s:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end))
end

-- 前端发送的是 encodeURIComponent(it.url)，而 it.url 本身已经是 encodeURIComponent 过的，
-- 所以这里是“二次编码 -> 两次解码”，两遍都要保留。
local function decode_file(raw)
    local f = unescape_file(raw or "")
    if f:match("%%") then f = unescape_file(f) end
    return f
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local _media_roots
local function media_roots()
    if _media_roots then return _media_roots end
    local roots, seen = {}, {}

    local function add(p)
        if not p or p == "" then return end
        p = p:gsub("/+$", "")
        if p == "" then p = "/" end
        if not seen[p] then seen[p] = true; roots[#roots + 1] = p end
    end

    -- 1) /etc/config/uhttpd 的 files 段：这是媒体站点实际使用的 home，最权威
    do
        local ok0, uci0 = pcall(require, "luci.model.uci")
        if ok0 and uci0 then
            local ok1, cur0 = pcall(uci0.cursor)
            if ok1 and cur0 then
                add(cur0:get("uhttpd", "files", "home"))
            end
        end
    end

    -- 2) UCI 显式指定
    local ok, uci = pcall(require, "luci.model.uci")
    if ok and uci then
        local ok2, cur = pcall(uci.cursor)
        if ok2 and cur then
            add(cur:get("media-center", "media", "root"))
            add(cur:get("media-center", "@media[0]", "root"))
        end
    end

    -- 3) /proc/mounts 里的 /mnt/* 挂载点（USB、移动硬盘、第二块盘）
    local mf = io.open("/proc/mounts", "r")
    if mf then
        for line in mf:lines() do
            local mp = line:match("^[^%s]+%s+(/[^%s]+)")
            if mp then
                mp = mp:gsub("\\040", " ")
                if mp:match("^/mnt/") then add(mp) end
            end
        end
        mf:close()
    end

    -- 4) 只是普通目录、不是挂载点的情况
    local p = io.popen("ls -1 /mnt 2>/dev/null")
    if p then
        for name in p:lines() do
            name = name:gsub("%s+$", "")
            if name ~= "" and name:sub(1, 1) ~= "." then add("/mnt/" .. name) end
        end
        p:close()
    end

    -- 5) 兜底
    add("/mnt")

    _media_roots = roots
    return roots
end

-- 把 URL 路径（/media/xxx）解析成真实文件路径；同时挡掉路径穿越
local function resolve_media(file)
    if not file or file == "" then return nil, "缺少 file 参数" end
    if file:find("%z") then return nil, "非法路径" end
    if file:sub(1, 1) ~= "/" then return nil, "非法路径：必须以 / 开头" end
    for seg in file:gmatch("[^/]+") do
        if seg == ".." then return nil, "非法路径" end
    end

    local roots = media_roots()
    for _, root in ipairs(roots) do
        local path = root .. file
        if file_exists(path) then return path end
    end
    return nil, "文件不存在: " .. file .. "（已尝试 " .. table.concat(roots, ", ") .. "）"
end

local function uri_encode_path(p)
    return (p:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-------------------------------------------------------------------------------
-- 目录浏览（Lua 备用实现）
--
-- uhttpd 的目录列表在个别目录上会直接断开连接（前端只看到
-- "Failed to fetch"）：超大目录、磁盘读目录异常、或文件名不是合法 UTF-8
-- 都可能触发。这里给网页端一份不依赖 autoindex 的列表，作为兜底。
-------------------------------------------------------------------------------

-- 把非法 UTF-8 字节替换成 ?，保证返回的 JSON 一定能被浏览器解析
local function utf8_sanitize(s)
    if not s or not s:find("[\128-\255]") then return s or "" end
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        local len = 0
        if c < 0x80 then
            len = 1
        elseif c >= 0xC2 and c <= 0xDF then
            len = 2
        elseif c >= 0xE0 and c <= 0xEF then
            len = 3
        elseif c >= 0xF0 and c <= 0xF4 then
            len = 4
        end

        if len == 1 then
            out[#out + 1] = string.char(c)
            i = i + 1
        elseif len > 1 and i + len - 1 <= n then
            local valid = true
            for k = 1, len - 1 do
                local cc = s:byte(i + k)
                if not cc or cc < 0x80 or cc > 0xBF then
                    valid = false
                    break
                end
            end
            if valid and len == 3 then
                local c1 = s:byte(i + 1)
                -- 过长编码 / UTF-16 代理区
                if (c == 0xE0 and c1 < 0xA0) or (c == 0xED and c1 > 0x9F) then valid = false end
            elseif valid and len == 4 then
                local c1 = s:byte(i + 1)
                if (c == 0xF0 and c1 < 0x90) or (c == 0xF4 and c1 > 0x8F) then valid = false end
            end
            if valid then
                out[#out + 1] = s:sub(i, i + len - 1)
                i = i + len
            else
                out[#out + 1] = "?"
                i = i + 1
            end
        else
            out[#out + 1] = "?"
            i = i + 1
        end
    end
    return table.concat(out)
end

local function path_is_dir(path)
    local ok, fs = pcall(require, "nixio.fs")
    if not ok or not fs then return false end
    local st = fs.stat(path)
    return st ~= nil and st.type == "dir"
end

local function resolve_media_dir(dir)
    if not dir or dir == "" then return nil, "缺少 path 参数" end
    if dir:find("%z") then return nil, "非法路径" end
    if dir:sub(1, 1) ~= "/" then return nil, "非法路径：必须以 / 开头" end
    for seg in dir:gmatch("[^/]+") do
        if seg == ".." then return nil, "非法路径" end
    end

    local rel = dir:gsub("/+$", "")
    local roots = media_roots()
    for _, root in ipairs(roots) do
        local candidate = root .. rel
        if path_is_dir(candidate) then return candidate end
    end
    return nil, "目录不存在: " .. dir .. "（已尝试 " .. table.concat(roots, ", ") .. "）"
end

local function list_directory(path)
    local ok, fs = pcall(require, "nixio.fs")
    if not ok or not fs then return nil, "服务器缺少 nixio.fs，无法浏览目录" end
    local ok2, iter = pcall(fs.dir, path)
    if not ok2 or not iter then return nil, "目录读取失败（可能没有权限）" end

    local entries, truncated = {}, false
    for name in iter do
        if name ~= "." and name ~= ".." and not name:match("%.part$") then
            local full = path .. "/" .. name
            local st = fs.stat(full) or fs.lstat(full)
            if st then
                local typ
                if st.type == "dir" then
                    typ = "directory"
                elseif st.type == "file" or st.type == "link" then
                    typ = "file"
                end
                if typ then
                    entries[#entries + 1] = {
                        name = utf8_sanitize(name),
                        type = typ,
                        size = (typ == "file") and tonumber(st.size) or nil,
                    }
                    -- 极端目录保护：避免一次生成几百 MB 的响应
                    if #entries >= 100000 then
                        truncated = true
                        break
                    end
                end
            end
        end
    end

    table.sort(entries, function(a, b) return a.name < b.name end)
    return entries, nil, truncated
end

-------------------------------------------------------------------------------
-- 探测
-------------------------------------------------------------------------------

local function probe_with_ffprobe(path)
    if not file_exists("/usr/bin/ffprobe") then return nil end
    local cmd = string.format(
        "LANG=C.UTF-8 /usr/bin/ffprobe -v error -analyzeduration 50M -probesize 50M "
        .. "-print_format json -show_format -show_streams %s 2>/dev/null",
        shell_quote(path))
    local p = io.popen(cmd, "r")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    if not out or not out:match("^{") then return nil end
    -- 校验能被解析，避免把半截 JSON 丢给前端
    local ok, data = pcall(function() return require("luci.jsonc").parse(out) end)
    if not ok or type(data) ~= "table" or type(data.format) ~= "table" then return nil end
    return out
end

-- 没有 ffprobe 时退回解析 ffmpeg 日志（旧行为，字段少一些，但不会让功能直接不可用）
local function probe_with_ffmpeg(path)
    local tmp = string.format("/tmp/ffprobe_%d_%d.log", os.time(), math.random(1000, 9999))
    os.execute(string.format(
        "LANG=C.UTF-8 /usr/bin/ffmpeg -hide_banner -analyzeduration 50M -probesize 50M -i %s > %s 2>&1",
        shell_quote(path), shell_quote(tmp)))

    local f = io.open(tmp, "r")
    if not f then return nil end
    local out = f:read("*a")
    f:close()
    os.remove(tmp)
    if not out or out == "" then return nil end

    local data = { format = {}, streams = {} }
    local fmt = out:match("Input #%d+, ([^,]+),") or out:match("Input #%d+, (.+), from")
    data.format.format_name = fmt or ""
    data.format.format_long_name = fmt or ""

    local h, m, s = out:match("Duration: (%d+):(%d+):(%d+%.%d+)")
    data.format.duration = h and tostring(math.floor(tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s))) or "0"
    local br = out:match("bitrate: (%d+) kb/s")
    data.format.bit_rate = br and tostring(tonumber(br) * 1000) or "0"

    for line in out:gmatch("[^\r\n]+") do
        local sidx = tonumber(line:match("Stream #%d+:(%d+)"))
        local is_default = line:match("%(default%)") and 1 or 0
        if line:match("Stream #%d+:%d+.*: Video:") then
            local codec = line:match("Video: ([^,]+)") or "unknown"
            local w, hh = line:match("(%d+)x(%d+)")
            local fps = line:match("([%d%.]+) fps")
            local vbr = line:match("(%d+) kb/s")
            local pix = line:match("Video: .-, ([%w_]+)")
            table.insert(data.streams, {
                index = sidx,
                codec_type = "video",
                codec_name = codec,
                width = tonumber(w) or 0,
                height = tonumber(hh) or 0,
                r_frame_rate = fps and (fps .. "/1") or "0/1",
                bit_rate = vbr and tostring(tonumber(vbr) * 1000) or "0",
                pix_fmt = pix or "",
                disposition = {
                    default = is_default,
                    attached_pic = line:match("attached pic") and 1 or 0
                }
            })
        elseif line:match("Stream #%d+:%d+.*: Audio:") then
            local codec = line:match("Audio: ([^%s,]+)") or "unknown"
            local sr = line:match("(%d+) Hz")
            local layout = line:match("Hz, ([^,]+)")
            local abr = line:match("(%d+) kb/s")
            local ch = 2
            if layout then
                if layout:match("mono") then ch = 1
                elseif layout:match("5%.1") then ch = 6
                elseif layout:match("7%.1") then ch = 8 end
            end
            table.insert(data.streams, {
                index = sidx,
                codec_type = "audio",
                codec_name = codec,
                sample_rate = sr and tostring(sr) or "0",
                channels = ch,
                channel_layout = layout or "",
                bit_rate = abr and tostring(tonumber(abr) * 1000) or "0",
                disposition = { default = is_default }
            })
        end
    end

    return require("luci.jsonc").stringify(data)
end

-- 返回首个真实视频流的编码名（跳过内嵌封面 attached_pic）
--   "none"    纯音频
--   "unknown" ffprobe 不可用，按“可直拷”处理
local function probe_video_codec(path)
    local out = probe_with_ffprobe(path)
    if not out then return "unknown" end
    local ok, data = pcall(function() return require("luci.jsonc").parse(out) end)
    if not ok or type(data) ~= "table" or type(data.streams) ~= "table" then return "unknown" end
    for _, s in ipairs(data.streams) do
        if s.codec_type == "video" then
            local disp = s.disposition or {}
            local pic = disp.attached_pic
            if pic ~= 1 and pic ~= true then
                return s.codec_name or "unknown"
            end
        end
    end
    return "none"
end

local function has_encoder(name)
    local f = io.popen("/usr/bin/ffmpeg -hide_banner -encoders 2>/dev/null")
    if not f then return false end
    local out = f:read("*a") or ""
    f:close()
    return out:find("%s" .. name .. "%s") ~= nil
end

function dlna_ffprobe()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")

    local file = decode_file(http.formvalue("file"))
    local path, err = resolve_media(file)
    if not path then http.write(jsonc.stringify({ error = err })); return end

    local out = probe_with_ffprobe(path) or probe_with_ffmpeg(path)
    if not out then
        http.write(jsonc.stringify({ error = "无法解析该文件（ffprobe / ffmpeg 都没有返回有效结果）" }))
        return
    end
    http.write(out)
end

-- 提取内嵌字幕为 WebVTT：GET /cgi-bin/luci/dlna/subtitle?file=...&index=...
-- 只支持文本字幕（SRT/ASS/SSA/mov_text 等）；PGS/DVD 图形字幕无法转成网页文本。
function dlna_subtitle()
    local http = require "luci.http"
    local file = decode_file(http.formvalue("file"))
    local index = tonumber(http.formvalue("index"))
    local path = resolve_media(file)
    if not path then
        http.status(404)
        http.prepare_content("text/plain; charset=utf-8")
        http.write("文件不存在")
        return
    end
    if not index or index < 0 then
        http.status(400)
        http.prepare_content("text/plain; charset=utf-8")
        http.write("缺少字幕流索引")
        return
    end
    if not file_exists("/usr/bin/ffmpeg") then
        http.status(500)
        http.prepare_content("text/plain; charset=utf-8")
        http.write("系统缺少 ffmpeg")
        return
    end

    local cmd = string.format(
        "LANG=C.UTF-8 /usr/bin/ffmpeg -hide_banner -loglevel error -i %s -map 0:%d -c:s webvtt -f webvtt -",
        shell_quote(path), index)
    local p = io.popen(cmd, "r")
    local data = p and p:read("*a") or ""
    if p then p:close() end

    if data and data:find("WEBVTT", 1, true) then
        http.prepare_content("text/vtt; charset=utf-8")
        http.write(data)
    else
        http.status(415)
        http.prepare_content("text/plain; charset=utf-8")
        http.write("该字幕不是文本字幕（可能是 PGS/DVD 图形字幕），网页播放器无法显示；可改用 MKV 输出后在电视或本地播放器里选择字幕。")
    end
end

-- iOS 16 及更早的 Safari 不支持 HEIC/HEIF；这里按需转成 JPEG 再给浏览器。
-- 优先 ImageMagick（magick/convert），其次 heif-convert，最后 ffmpeg。
function dlna_image()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local file = decode_file(http.formvalue("file"))
    local path = resolve_media(file)
    if not path then
        http.status(404); http.prepare_content("text/plain; charset=utf-8"); http.write("文件不存在"); return
    end
    local ext = path:match("%.([^.]+)$")
    ext = ext and ext:lower() or ""
    local needs = (ext == "heic" or ext == "heif" or ext == "avif" or ext == "tif" or ext == "tiff")
    if not needs then
        http.status(302); http.header("Location", file); return
    end

    local data = nil
    for _, bin in ipairs({ "magick", "convert" }) do
        if sys.call("command -v " .. bin .. " >/dev/null 2>&1") == 0 then
            local cmd = string.format(
                "LANG=C.UTF-8 %s %s -auto-orient -resize %s -quality 85 jpg:- 2>/dev/null",
                bin, shell_quote(path), shell_quote("1600x1600>"))
            local p = io.popen(cmd, "r")
            if p then data = p:read("*a"); p:close() end
            if data and #data > 0 then break end
        end
    end
    if (not data or #data == 0) and sys.call("command -v heif-convert >/dev/null 2>&1") == 0 then
        local tmp = string.format("/tmp/nm_img_%d_%d.jpg", os.time(), math.random(1000, 9999))
        sys.exec(string.format("heif-convert -q 85 %s %s >/dev/null 2>&1",
            shell_quote(path), shell_quote(tmp)))
        local f = io.open(tmp, "rb")
        if f then data = f:read("*a"); f:close() end
        os.remove(tmp)
    end
    if (not data or #data == 0) and file_exists("/usr/bin/ffmpeg") then
        local cmd = string.format(
            "LANG=C.UTF-8 /usr/bin/ffmpeg -hide_banner -loglevel error -i %s -frames:v 1 "
            .. "-vf scale=1600:-2:force_original_aspect_ratio=decrease -f image2 -vcodec mjpeg - 2>/dev/null",
            shell_quote(path))
        local p = io.popen(cmd, "r")
        if p then data = p:read("*a"); p:close() end
    end
    if not data or #data == 0 then
        http.status(415)
        http.prepare_content("text/plain; charset=utf-8")
        http.write("无法转换该图片：请安装带 HEIC 支持的 ImageMagick（magick/convert）或 heif-convert。")
        return
    end
    http.header("Cache-Control", "public, max-age=86400")
    http.prepare_content("image/jpeg")
    http.write(data)
end

-- 目录列表兜底接口：GET /cgi-bin/luci/dlna/list_dir?path=<encodeURIComponent(路径)>
-- http.formvalue 已经解过一次编码，这里直接使用，避免文件名里的 % 被二次解码
function dlna_list_dir()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")

    local dir = http.formvalue("path") or ""
    -- 正常情况下 formvalue 已经解码；个别环境若仍返回 %2F 开头，这里再解一次
    if dir:sub(1, 1) ~= "/" then
        local d2 = unescape_file(dir)
        if d2:sub(1, 1) == "/" then dir = d2 end
    end
    local path, err = resolve_media_dir(dir)
    if not path then
        http.write(jsonc.stringify({ error = err or "目录不存在" }))
        return
    end

    local entries, lerr, truncated = list_directory(path)
    if not entries then
        http.write(jsonc.stringify({ error = lerr or "读取目录失败" }))
        return
    end

    http.write(jsonc.stringify({
        status = "success",
        url = dir,
        count = #entries,
        truncated = truncated or false,
        entries = entries,
    }))
end

-------------------------------------------------------------------------------
-- 转封装 / 转码
-- 前端传 plan：
--   {"container":"mp4","streams":[{"index":0,"type":"video","action":"copy"},
--                                 {"index":1,"type":"audio","action":"aac2"}]}
-- 处理方式：copy / ignore / aac2 / aac51 / ac351（视频只允许 copy、ignore）
-- 没有 plan 时退回旧行为：视频直拷 + 首条音轨转 AAC 2CH
-------------------------------------------------------------------------------

local ACODEC_SPEC =
{
    aac2  = { codec = "aac", br = "192k", ac = 2 },
    aac51 = { codec = "aac", br = "384k", ac = 6 },
    ac351 = { codec = "ac3", br = "640k", ac = 6 }
}

local function build_plan_args(plan, container)
    local args = {}
    local ov, oa, osn = 0, 0, 0
    local audio_out = {}
    local has_video = false

    for _, s in ipairs(plan.streams) do
        local idx = tonumber(s.index)
        local typ = tostring(s.type or "")
        local copy = (s.copy == true)
        local trans = tostring(s.transcode or "none")

        if idx and idx >= 0 then
            if typ == "video" then
                if copy then
                    args[#args + 1] = string.format("-map 0:%d -c:v:%d copy", idx, ov)
                    ov = ov + 1
                    has_video = true
                end
            elseif typ == "audio" then
                -- 同一条源音轨可以先复制原轨、再转一份，这是 #4 的关键
                if copy then
                    args[#args + 1] = string.format("-map 0:%d -c:a:%d copy", idx, oa)
                    audio_out[#audio_out + 1] = { oi = oa, trans = false }
                    oa = oa + 1
                end
                if ACODEC_SPEC[trans] then
                    local spec = ACODEC_SPEC[trans]
                    args[#args + 1] = string.format(
                        "-map 0:%d -c:a:%d %s -b:a:%d %s -ac:a:%d %d",
                        idx, oa, spec.codec, oa, spec.br, oa, spec.ac)
                    audio_out[#audio_out + 1] = { oi = oa, trans = true }
                    oa = oa + 1
                end
            elseif typ == "subtitle" then
                -- MKV 可直接复制文本/图形字幕；MP4/MOV 只支持文本字幕转 mov_text；
                -- TS/AVI 不支持字幕，忽略。
                local codec = tostring(s.codec or ""):lower()
                local image_sub = codec:find("pgs", 1, true) or codec:find("dvd_subtitle", 1, true)
                    or codec:find("dvb_subtitle", 1, true) or codec:find("xsub", 1, true)
                if copy then
                    if container == "mkv" then
                        local scodec = "copy"
                        -- mov_text/webvtt 不能直接塞进 Matroska，统一转成 SRT；
                        -- ASS/SSA 和 PGS/DVD 图形字幕保持原样。
                        if codec == "mov_text" or codec == "webvtt" or codec == "text" then
                            scodec = "srt"
                        end
                        args[#args + 1] = string.format("-map 0:%d -c:s:%d %s", idx, osn, scodec)
                        osn = osn + 1
                    elseif (container == "mp4" or container == "mov") and not image_sub then
                        args[#args + 1] = string.format("-map 0:%d -c:s:%d mov_text", idx, osn)
                        osn = osn + 1
                    end
                end
            end
        end
    end

    -- 有转码音轨时，把转码轨设为 default，保证浏览器默认出声；
    -- 原轨仍然保留且可被电视手动选择
    local has_trans = false
    for _, a in ipairs(audio_out) do if a.trans then has_trans = true end end
    if has_trans then
        for _, a in ipairs(audio_out) do
            args[#args + 1] = string.format("-disposition:a:%d %s", a.oi, a.trans and "default" or "0")
        end
    end

    return table.concat(args, " "), (ov + oa + osn), has_video
end

-------------------------------------------------------------------------------
-- 后台转封装任务状态
--
-- 任务元数据 /tmp/aac_<token>.meta：
--   第 1 行：源文件 URL 路径（未编码）
--   第 2 行：输出文件 URL（已编码）
--   之后：key=value（token / duration / started / container）
-- 进度写在 /tmp/aac_<token>.prog，日志 /tmp/aac_<token>.log。
-- 刷新/关闭网页后，前端用 /dlna/tasks 找回任务；/tmp 重启即清空，
-- 不存在“重启后还显示旧任务”的问题。
-------------------------------------------------------------------------------

local function read_task_meta(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local meta = {}
    meta.file = f:read("*l") or ""
    meta.new_file_url = f:read("*l") or ""
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then meta[k] = v end
    end
    f:close()
    return meta
end

local function read_progress_file(token)
    local f = io.open("/tmp/aac_" .. token .. ".prog", "r")
    if not f then return nil end
    local content = f:read("*a") or ""
    f:close()

    local out_time_us, speed, total_size = 0, "0x", 0
    for v in content:gmatch("out_time_us=(%d+)") do out_time_us = tonumber(v) or 0 end
    for v in content:gmatch("total_size=(%d+)") do total_size = tonumber(v) or 0 end
    for v in content:gmatch("speed=%s*([%d%.x]+)") do speed = v end

    return {
        out_time_us = out_time_us,
        total_size = total_size,
        speed = speed,
        is_end = content:match("progress=end") ~= nil,
    }
end

local function tail_text(path, max)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a") or ""
    f:close()
    return s:sub(-(max or 600))
end

local function task_is_running(token)
    if token == "" then return false end
    return require("luci.sys").call("pgrep -f 'TRANS_" .. token .. "' >/dev/null 2>&1") == 0
end

local function system_load()
    local f = io.open("/proc/loadavg", "r")
    if not f then return "0.00" end
    local s = f:read("*l") or ""
    f:close()
    return s:match("^(%S+)") or "0.00"
end

-- 汇总单个任务的状态；running/starting/done/error
local function collect_task(token, meta_path, now)
    local meta = read_task_meta(meta_path)
    if not meta then return nil end

    local fs = require "nixio.fs"
    local st = fs.stat(meta_path)
    local started = tonumber(meta.started or "") or (st and st.mtime) or 0
    local duration = tonumber(meta.duration or "") or 0
    local prog = read_progress_file(token)
    local running = task_is_running(token)
    local prog_path = "/tmp/aac_" .. token .. ".prog"
    local pst = fs.stat(prog_path)
    local updated = started
    if pst and pst.mtime > updated then updated = pst.mtime end

    local status
    if prog and prog.is_end and running then
        -- ffmpeg 已输出 progress=end，但进程还在收尾（trailer / +faststart / mv）
        status = "finalizing"
    elseif prog and prog.is_end and not running then
        if meta.out_path and meta.out_path ~= "" and not file_exists(meta.out_path) then
            status = "error"
        else
            status = "done"
        end
    elseif running then
        status = prog and "running" or "starting"
    elseif prog then
        -- 进程刚退出时最后一块进度可能还没落盘，给 4 秒缓冲
        if pst and (now - pst.mtime) < 4 then
            status = "running"
        else
            status = "error"
        end
    else
        if (now - started) < 10 then status = "starting" else status = "error" end
    end

    local percent
    if status == "done" or status == "finalizing" then
        percent = 100
    elseif duration > 0 and prog and prog.out_time_us then
        percent = math.floor(prog.out_time_us / duration / 10000)
        if percent > 99 then percent = 99 end
    end

    local info = {
        token = token,
        file = meta.file or "",
        new_file_url = meta.new_file_url or "",
        container = meta.container or "mp4",
        duration = duration,
        status = status,
        is_done = (status == "done"),
        batch = (meta.batch == "1"),
        started = started,
        updated = updated,
        load = system_load(),
    }
    if percent then info.percent = percent end
    if prog then
        info.out_time_us = prog.out_time_us
        info.total_size = prog.total_size
        info.speed = prog.speed
    end
    if status == "error" then
        if prog and prog.is_end and meta.out_path and meta.out_path ~= "" and not file_exists(meta.out_path) then
            info.message = "输出文件未生成（可能是磁盘空间不足或改名失败）"
        else
            info.message = "FFmpeg 进程意外退出"
        end
        info.log = utf8_sanitize(tail_text("/tmp/aac_" .. token .. ".log", 600))
    end
    return info
end

function dlna_extract_audio()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")

    local file = decode_file(http.formvalue("file"))
    local path, err = resolve_media(file)
    if not path then http.write(jsonc.stringify({ error = err })); return end

    if not file_exists("/usr/bin/ffmpeg") then
        http.write(jsonc.stringify({ error = "系统缺少 /usr/bin/ffmpeg，无法转封装" }))
        return
    end

    -- 时长由前端在“检测文件信息”时已经拿到，直接带过来，
    -- 这样刷新页面后进度条还能算出百分比。
    local duration = tonumber(http.formvalue("duration")) or 0
    if duration < 0 then duration = 0 end

    -- 音频导出格式：m4a / mp3 / wav。为空时保持原来的 plan/转封装逻辑。
    local format = (http.formvalue("format") or ""):lower()
    local prefix = http.formvalue("prefix") or ""
    -- 文件名前缀：去掉控制字符和路径分隔符，限制长度
    prefix = prefix:gsub("[%c/\\]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    prefix = prefix:gsub("^%.+", "")  -- 避免生成隐藏文件
    if #prefix > 120 then prefix = prefix:sub(1, 120) end
    local audio_index = tonumber(http.formvalue("audio_index"))
    if audio_index and audio_index < 0 then audio_index = nil end
    local is_batch = (http.formvalue("batch") == "1") and "1" or "0"

    local container = "mp4"
    local args, nstream, plan_seen = nil, 0, false
    local has_video = false
    local audio_only = (format == "m4a" or format == "mp3" or format == "wav")

    if audio_only then
        local map = audio_index and ("-map 0:" .. tostring(audio_index) .. "?") or "-map 0:a:0?"
        if format == "m4a" then
            container = "m4a"
            args = map .. " -vn -c:a aac -b:a 192k -ac 2"
        elseif format == "mp3" then
            container = "mp3"
            local enc = "libmp3lame"
            if not has_encoder(enc) then
                if has_encoder("libshine") then
                    enc = "libshine"
                else
                    http.write(jsonc.stringify({ error = "系统 ffmpeg 未编译 MP3 编码器（libmp3lame/libshine）" }))
                    return
                end
            end
            args = map .. " -vn -c:a " .. enc .. " -b:a 192k -ac 2"
        else
            container = "wav"
            args = map .. " -vn -c:a pcm_s16le"
        end
        nstream = 1
        plan_seen = true
        -- 批量转码没有现成时长，补一次 ffprobe 方便显示百分比/估算 WAV 体积
        if duration <= 0 then
            local pout = probe_with_ffprobe(path)
            if pout then
                local pok, pdata = pcall(function() return jsonc.parse(pout) end)
                if pok and type(pdata) == "table" and type(pdata.format) == "table" then
                    duration = tonumber(pdata.format.duration) or 0
                end
            end
        end
    else
        local plan_raw = http.formvalue("plan")
        if plan_raw and plan_raw ~= "" then
            local ok, plan = pcall(function() return jsonc.parse(plan_raw) end)
            if ok and type(plan) == "table" and type(plan.streams) == "table" then
                plan_seen = true
                local pc = tostring(plan.container or "")
                if pc == "ts" or pc == "mkv" or pc == "mov" or pc == "avi" then
                    container = pc
                end
                args, nstream, has_video = build_plan_args(plan, container)
            end
        end
    end

    if plan_seen then
        -- 明确给了 plan：全忽略就报错，不要偷偷套默认值
        if nstream == 0 or not args or args == "" then
            http.write(jsonc.stringify({ error = "没有选择任何要保留的数据流" }))
            return
        end
    else
        -- 旧前端（没有 plan）：视频直拷 + 首条音轨 AAC 2CH
        args = "-map 0:v:0? -c:v copy -map 0:a:0? -c:a aac -b:a 192k -ac 2"
        has_video = true
    end

    local ext
    if container == "ts" then ext = ".ts"
    elseif container == "mkv" then ext = ".mkv"
    elseif container == "mov" then ext = ".mov"
    elseif container == "avi" then ext = ".avi"
    elseif container == "m4a" then ext = ".m4a"
    elseif container == "mp3" then ext = ".mp3"
    elseif container == "wav" then ext = ".wav"
    else ext = ".mp4" end

    local dir = path:match("^(.*)/[^/]+$") or "/mnt"
    local orig_name = path:match("([^/]+)$") or "media"
    local base_name = orig_name:gsub("%.[^.]+$", ""):gsub("[%c/]", "_")
    local token = tostring(os.time()) .. tostring(math.random(100, 999))

    -- 音轨切换用固定名字做缓存：同一源文件的同一音轨只生成一次。
    -- 普通转封装仍然每次生成新文件（带 token）。
    local cache_key = (http.formvalue("cache_key") or ""):gsub("[^%w_]", "")
    if #cache_key > 24 then cache_key = cache_key:sub(1, 24) end
    local suffix = (cache_key ~= "") and cache_key or token
    local new_name = prefix .. base_name .. "_TRANS_" .. suffix .. ext
    local out_file = dir .. "/" .. new_name
    -- 极端情况：源文件本身就叫 xxx_TRANS_A2.mp4，避免把源文件当成缓存输出
    if cache_key ~= "" and out_file == path then
        cache_key = ""
        suffix = token
        new_name = prefix .. base_name .. "_TRANS_" .. suffix .. ext
        out_file = dir .. "/" .. new_name
    end
    -- ffmpeg 先写隐藏的 .part，成功后再原子改名，避免播放器读到半成品，
    -- 也避免 +faststart 收尾阶段（大文件可能几十秒）被误认为已完成。
    local part_file = dir .. "/." .. base_name .. "_TRANS_" .. token .. ".part"

    -- 返回给前端的 URL：保留原目录（URL 形式），文件名做百分号编码
    local url_dir = file:gsub("([^/]+)$", "")
    local new_url = uri_encode_path(url_dir .. new_name)

    local nfs = require "nixio.fs"

    -- 缓存命中：同一条音轨之前已经完整生成过，直接复用
    if cache_key ~= "" and file_exists(out_file) then
        local ost = nfs.stat(out_file)
        local sst = nfs.stat(path)
        if ost and ost.size and ost.size > 0
            and (not ost.mtime or not sst or not sst.mtime or ost.mtime >= sst.mtime) then
            http.write(jsonc.stringify({
                status = "success", cached = true, token = "",
                new_file_url = new_url, container = container, args = "",
            }))
            return
        end
    end

    -- 空间检查：视频直拷时输出体积约等于源文件，提前失败比写到一半更好
    local src_size = 0
    local sstat = nfs.stat(path)
    if sstat then src_size = tonumber(sstat.size) or 0 end
    local need = has_video and (src_size * 1.05 + 64 * 1024 * 1024) or (128 * 1024 * 1024)
    if container == "wav" then
        if duration > 0 then
            -- 48kHz/16bit/2ch 约 192KB/s，再加 16MB 余量
            need = duration * 192000 * 1.05 + 16 * 1024 * 1024
        else
            need = 512 * 1024 * 1024
        end
    end
    local vfs = nfs.statvfs and nfs.statvfs(dir) or nil
    if vfs then
        local frsize = tonumber(vfs.frsize or vfs.bsize)
        local avail = tonumber(vfs.bavail or vfs.bfree)
        if frsize and avail and frsize > 0 then
            local free = avail * frsize
            if free < need then
                http.write(jsonc.stringify({
                    error = string.format("磁盘空间不足：预计需要约 %.0f MB，当前可用约 %.0f MB",
                        need / 1048576, free / 1048576),
                }))
                return
            end
        end
    end

    local prog_file = "/tmp/aac_" .. token .. ".prog"
    local log_file = "/tmp/aac_" .. token .. ".log"
    local meta_file = "/tmp/aac_" .. token .. ".meta"

    -- 同一源文件的旧任务清掉：避免旧输出（如之前的纯音频 .ts）被当成当前任务，
    -- 同时结束可能还在跑的旧 ffmpeg，防止同一文件被转两份。
    local old = io.popen("ls /tmp/aac_*.meta 2>/dev/null")
    if old then
        for mline in old:lines() do
            local of = io.open(mline, "r")
            if of then
                local s0 = of:read("*l")
                of:close()
                if s0 == file then
                    local oldtoken = mline:match("aac_(%d+)%.meta")
                    if oldtoken then
                        if task_is_running(oldtoken) then
                            sys.exec("pkill -f 'TRANS_" .. oldtoken .. "' 2>/dev/null")
                        end
                        local oldmeta = read_task_meta(mline)
                        if oldmeta and oldmeta.part_path and oldmeta.part_path ~= "" then
                            os.remove(oldmeta.part_path)
                        end
                        os.remove("/tmp/aac_" .. oldtoken .. ".prog")
                        os.remove("/tmp/aac_" .. oldtoken .. ".log")
                    end
                    os.remove(mline)
                end
            end
        end
        old:close()
    end

    -- 元数据用于刷新/关闭网页后找回任务
    local mf = io.open(meta_file, "w")
    if mf then
        mf:write(file, "\n", new_url, "\n")
        mf:write("token=", token, "\n")
        mf:write("duration=", tostring(math.floor(duration + 0.5)), "\n")
        mf:write("started=", tostring(os.time()), "\n")
        mf:write("container=", container, "\n")
        mf:write("out_path=", out_file, "\n")
        mf:write("part_path=", part_file, "\n")
        mf:write("cache_key=", cache_key, "\n")
        mf:write("batch=", is_batch, "\n")
        mf:close()
    end

    sys.exec("pkill -f 'TRANS_" .. token .. "' 2>/dev/null")

    local tail
    if container == "ts" then
        tail = "-f mpegts"
    elseif container == "mkv" then
        tail = "-f matroska"
    elseif container == "mov" then
        tail = "-avoid_negative_ts make_zero -movflags +faststart -f mov"
    elseif container == "avi" then
        tail = "-f avi"
    elseif container == "mp3" then
        tail = "-f mp3"
    elseif container == "wav" then
        tail = "-f wav"
    elseif container == "m4a" then
        tail = "-avoid_negative_ts make_zero -movflags +faststart -f ipod"
    else
        tail = "-avoid_negative_ts make_zero -movflags +faststart -f mp4"
    end

    -- 先写 .part，ffmpeg 完全退出（含 +faststart 收尾）后再 mv 成正式文件。
    -- 这样播放器/目录不会看到半成品，进度框也能准确等到“真正完成”。
    local cmd = string.format(
        "(LANG=C.UTF-8 /usr/bin/ffmpeg -hide_banner -analyzeduration 50M -probesize 50M "
        .. "-i %s %s %s %s -progress %s && mv -f %s %s) >> %s 2>&1 &",
        shell_quote(path), args, tail, shell_quote(part_file), shell_quote(prog_file),
        shell_quote(part_file), shell_quote(out_file), shell_quote(log_file))
    os.execute(cmd)

    http.write('{"status":"success","cached":false,"token":"' .. token .. '","new_file_url":' .. jsonc.stringify(new_url)
        .. ',"container":"' .. container .. '","args":' .. jsonc.stringify(args) .. '}')
end

function dlna_check_task()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local file = decode_file(http.formvalue("file"))
    http.prepare_content("application/json")

    if file == "" then http.write('{"status":"none"}'); return end

    -- 只认“正在运行”的任务：任务完成后输出文件已经在目录里，
    -- 再自动接管播放只会让旧任务（比如以前那个纯音频 .ts）劫持原视频。
    local p = io.popen("ls -t /tmp/aac_*.meta 2>/dev/null")
    if p then
        for line in p:lines() do
            local token = line:match("aac_(%d+)%.meta")
            if token then
                local mf = io.open(line, "r")
                if mf then
                    local src = mf:read("*l")
                    mf:close()
                    if src == file then
                        local info = collect_task(token, line, os.time())
                        if info and (info.status == "running" or info.status == "starting" or info.status == "finalizing") then
                            p:close()
                            info.status = "found"
                            info.is_done = false
                            http.write_json(info)
                            return
                        end
                    end
                end
            end
        end
        p:close()
    end
    http.write('{"status":"none"}')
end

function dlna_get_progress()
    local http = require "luci.http"
    local token = (http.formvalue("token") or ""):gsub("%D", "")
    http.prepare_content("application/json")

    if token == "" then http.write('{"error":"缺少 token"}'); return end

    local info = collect_task(token, "/tmp/aac_" .. token .. ".meta", os.time())
    if not info then
        http.write('{"error":"任务不存在或已被清理"}')
        return
    end
    http.write_json(info)
end

-- 刷新/关闭网页后找回任务：返回最近的任务（运行中的优先）
function dlna_tasks()
    local http = require "luci.http"
    local now = os.time()
    http.prepare_content("application/json")

    local metas = {}
    local p = io.popen("ls -t /tmp/aac_*.meta 2>/dev/null")
    if p then
        for line in p:lines() do
            local token = line:match("aac_(%d+)%.meta$")
            if token then metas[#metas + 1] = { token = token, path = line } end
        end
        p:close()
    end

    local tasks = {}
    for _, m in ipairs(metas) do
        local info = collect_task(m.token, m.path, now)
        if info then
            local active = (info.status == "running" or info.status == "starting" or info.status == "finalizing")
            local keep = active
                or ((info.status == "done" or info.status == "error") and (now - info.updated) < 86400)
            if keep then
                tasks[#tasks + 1] = info
            elseif (now - info.started) > 86400 then
                -- /tmp 也要定期清理，避免任务多了以后越积越多
                local oldmeta = read_task_meta(m.path)
                if oldmeta and oldmeta.part_path and oldmeta.part_path ~= "" then
                    os.remove(oldmeta.part_path)
                end
                os.remove(m.path)
                os.remove("/tmp/aac_" .. m.token .. ".prog")
                os.remove("/tmp/aac_" .. m.token .. ".log")
            end
        end
    end

    table.sort(tasks, function(a, b)
        local ar = (a.status == "running" or a.status == "starting" or a.status == "finalizing") and 1 or 0
        local br = (b.status == "running" or b.status == "starting" or b.status == "finalizing") and 1 or 0
        if ar ~= br then return ar > br end
        return (a.updated or 0) > (b.updated or 0)
    end)

    http.write_json({ status = "success", tasks = tasks })
end

function dlna_cancel_extract()
    local http = require "luci.http"
    local token = (http.formvalue("token") or ""):gsub("%D", "")
    local new_url = decode_file(http.formvalue("new_url"))
    http.prepare_content("application/json")

    if token == "" then http.write('{"error":"缺少 token"}'); return end

    -- 先读元数据，拿到 .part 和最终输出路径
    local meta = read_task_meta("/tmp/aac_" .. token .. ".meta")

    require("luci.sys").exec("pkill -f 'TRANS_" .. token .. "'; rm -f /tmp/aac_" .. token .. ".*")

    if meta then
        if meta.part_path and meta.part_path ~= "" then os.remove(meta.part_path) end
        if meta.out_path and meta.out_path ~= "" then os.remove(meta.out_path) end
    end

    if new_url ~= "" then
        local path = resolve_media(new_url)
        if path then os.remove(path) end
    end
    http.write('{"status":"success"}')
end

-------------------------------------------------------------------------------
-- DLNA
-------------------------------------------------------------------------------

-- 本地投屏：只接受来自局域网的请求，不再需要手动密钥。
-- 安全边界：
--   1) 客户端来源必须是私有地址（公网/WAN 直接访问一律拒绝）；
--   2) 带 Origin 的浏览器请求必须同源，且 Host 是局域网地址，
--      防止外部网页跨站偷发投屏/控制指令，也挡住 DNS rebinding。
local function ip_is_private(ip)
    if not ip or ip == "" then return false end
    local mapped = ip:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
    if mapped then ip = mapped end
    if ip == "127.0.0.1" or ip == "::1" then return true end
    if ip:match("^10%.") or ip:match("^192%.168%.") or ip:match("^169%.254%.") then return true end
    local second = tonumber(ip:match("^172%.(%d+)%."))
    if second and second >= 16 and second <= 31 then return true end
    if ip:match("^[fF][cCdD]") or ip:match("^[fF][eE][89abAB]") then return true end
    return false
end

-- 反向代理会把真实客户端地址放在 X-Real-IP / X-Forwarded-For；
-- 只有请求确实来自本机反向代理时才信任这些头，避免直接访问 80 端口时伪造。
local function dlna_client_ip()
    local http = require "luci.http"
    local raddr = http.getenv("REMOTE_ADDR") or ""
    if raddr == "127.0.0.1" or raddr == "::1" then
        local real = http.getenv("HTTP_X_REAL_IP") or ""
        if real == "" then
            -- X-Forwarded-For 由代理追加；取最后一跳（代理看到的真实客户端），
            -- 避免客户端自己伪造前面的条目。
            local xff = http.getenv("HTTP_X_FORWARDED_FOR") or ""
            local last
            for ip in xff:gmatch("[^,%s]+") do last = ip end
            real = last or ""
        end
        if real ~= "" then return real end
    end
    return raddr
end

-- 去掉端口和 IPv6 方括号，便于比较 Origin 与 Host
local function normalize_host(host)
    host = (host or ""):lower()
    local bracketed = host:match("^%[([^%]]+)%]")
    if bracketed then return bracketed end
    -- 多于一个冒号按 IPv6 处理，不把最后一段误当端口
    local _, colons = host:gsub(":", "")
    if colons <= 1 then host = host:gsub(":%d+$", "") end
    return host
end

local function host_is_lan(host)
    if not host or host == "" then return false end
    host = normalize_host(host)
    if host == "localhost" or host == "::1" then return true end
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return ip_is_private(host) end
    -- 带冒号的是 IPv6，只接受回环/ULA/链路本地
    if host:find(":", 1, true) then return ip_is_private(host) end
    if host:match("^[^.]+$") then return true end
    return host:match("%.local$") ~= nil or host:match("%.lan$") ~= nil
        or host:match("%.home$") ~= nil or host:match("%.internal$") ~= nil
        or host:match("%.home%.arpa$") ~= nil
end

local function url_is_lan(url)
    url = tostring(url or "")
    local host = url:match("^https?://(%[[^%]]+%])") or url:match("^https?://([^/:]+)")
    if not host then return false end
    return host_is_lan(host)
end

local function dlna_require_post()
    local http = require "luci.http"
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        http.status(405, "Method Not Allowed")
        http.header("Allow", "POST")
        http.prepare_content("application/json")
        http.write('{"status":"error","message":"请使用 POST 请求"}')
        return false
    end
    return true
end

local function dlna_api_guard()
    local http = require "luci.http"
    local function deny(msg)
        http.status(403, "Forbidden")
        http.prepare_content("application/json")
        http.write('{"status":"error","message":"' .. msg .. '"}')
        return false
    end

    if not ip_is_private(dlna_client_ip()) then
        return deny("投屏接口仅限本地局域网访问")
    end

    local origin = http.getenv("HTTP_ORIGIN") or ""
    if origin ~= "" then
        local ohost = origin:match("^https?://([^/]+)$")
        local hhost = http.getenv("HTTP_HOST") or ""
        if not ohost or not host_is_lan(ohost) or not host_is_lan(hhost)
            or normalize_host(ohost) ~= normalize_host(hhost) then
            return deny("拒绝跨站投屏请求")
        end
    end
    return true
end

local function parse_upnp_device(xml, loc)
    if not xml or xml == "" then return nil end
    local name = xml:match("<[fF]riendlyName>(.-)</[fF]riendlyName>") or "未知设备"
    name = name:gsub("^%s+", ""):gsub("%s+$", "")

    local ctrl
    for svc in xml:gmatch("<service%s*>(.-)</service>") do
        local stype = svc:match("<serviceType>(.-)</serviceType>") or ""
        if stype:match("AVTransport") then
            ctrl = svc:match("<controlURL>(.-)</controlURL>")
            if ctrl then break end
        end
    end
    if not ctrl then
        ctrl = xml:match("<[cC]ontrolURL>(.-)</[cC]ontrolURL>")
    end
    if not ctrl then return nil end
    ctrl = ctrl:gsub("^%s+", ""):gsub("%s+$", "")

    local base = loc:match("^(https?://[^/]+)")
    if not base then return nil end
    if ctrl:match("^https?://") then return ctrl, name end
    if ctrl:sub(1, 1) ~= "/" then ctrl = "/" .. ctrl end
    return base .. ctrl, name
end

function dlna_discover()
    local http = require "luci.http"
    if not dlna_api_guard() then return end

    local devices = {}
    local f = io.open("/tmp/dlna_devices.json", "r")
    if f then
        local content = f:read("*a") or ""
        f:close()
        local ok, arr = pcall(function() return require("luci.jsonc").parse(content) end)
        if ok and type(arr) == "table" then
            for _, d in ipairs(arr) do
                -- 只返回局域网设备：缓存里可能残留旧版本从远端收到的 SSDP 结果
                if type(d) == "table" and d.url and d.name and url_is_lan(d.url) then
                    table.insert(devices, { name = d.name, control_url = d.url })
                end
            end
        else
            -- 兼容旧守护进程写出的非标准顺序 JSON
            for url, name in content:gmatch('"url":"(.-)","name":"(.-)"') do
                if url_is_lan(url) then
                    table.insert(devices, { name = name, control_url = url })
                end
            end
        end
    end
    http.prepare_content("application/json")
    -- 空 Lua 表在某些 jsonc 版本里会编码成 {}，这里明确返回数组
    if #devices == 0 then
        http.write("[]")
    else
        http.write_json(devices)
    end
end

-- 自动发现用的轻量探针：返回固定标记、本地设备数量和本机 LAN IPv4，
-- 不返回设备名/控制地址。只开放这一个接口的 CORS/PNA，供远程播放页
-- 从浏览器里探测本地路由器；真正的投屏/控制仍然要求同源、私网来源和 POST。
local function dlna_lan_ipv4()
    -- UCI 的 LAN 地址最可靠；没有再退回接口枚举里的 br-lan
    local ok3, uci = pcall(require, "luci.model.uci")
    if ok3 and uci then
        local ok4, cur = pcall(uci.cursor)
        if ok4 and cur then
            local ip = cur:get("network", "lan", "ipaddr")
            if ip and ip:match("^%d+%.%d+%.%d+%.%d+$") then return ip end
        end
    end
    local ok, nixio = pcall(require, "nixio")
    if ok and nixio and nixio.getifaddrs then
        local ok2, ifs = pcall(nixio.getifaddrs)
        if ok2 and type(ifs) == "table" then
            local fallback
            for _, ifa in ipairs(ifs) do
                local name = ifa.name or ""
                local addr = ifa.addr or ""
                if ifa.family == "inet" and name ~= "lo" and addr:match("^%d+%.%d+%.%d+%.%d+$") then
                    if name == "br-lan" or name:find("lan", 1, true) then return addr end
                    if not fallback and ip_is_private(addr) then fallback = addr end
                end
            end
            if fallback then return fallback end
        end
    end
    return ""
end

function dlna_ping()
    local http = require "luci.http"
    local origin = http.getenv("HTTP_ORIGIN") or ""
    if origin:match("^https?://[^/]+$") then
        http.header("Access-Control-Allow-Origin", origin)
        http.header("Vary", "Origin")
    else
        http.header("Access-Control-Allow-Origin", "*")
    end
    http.header("Access-Control-Allow-Methods", "GET, OPTIONS")
    http.header("Access-Control-Allow-Headers", "*")
    http.header("Access-Control-Allow-Private-Network", "true")
    http.header("Access-Control-Max-Age", "600")
    http.header("Cache-Control", "no-store")

    if http.getenv("REQUEST_METHOD") == "OPTIONS" then
        http.status(204, "No Content")
        return
    end

    local count = 0
    local f = io.open("/tmp/dlna_devices.json", "r")
    if f then
        local content = f:read("*a") or ""
        f:close()
        local ok, arr = pcall(function() return require("luci.jsonc").parse(content) end)
        if ok and type(arr) == "table" then
            for _, d in ipairs(arr) do
                if type(d) == "table" and d.url and url_is_lan(d.url) then
                    count = count + 1
                end
            end
        end
    end

    http.prepare_content("application/json")
    http.write('{"ok":true,"app":"media-center","devices":' .. count
        .. ',"lan_ip":"' .. dlna_lan_ipv4() .. '"}')
end

-- 手动输入电视 IP：向该 IP 单播 M-SEARCH，拿 LOCATION 后解析 AVTransport
function dlna_probe()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    if not dlna_api_guard() then return end
    if not dlna_require_post() then return end

    local ip = (http.formvalue("ip") or ""):gsub("%s", "")
    if not ip:match("^%d+%.%d+%.%d+%.%d+$") then
        http.write('{"status":"error","message":"IP 格式不正确"}')
        return
    end
    if not ip_is_private(ip) then
        http.write('{"status":"error","message":"只支持本地局域网 IP"}')
        return
    end

    local nixio = require "nixio"
    local sock = nixio.socket("inet", "dgram")
    if not sock then
        http.write('{"status":"error","message":"无法创建 UDP socket"}')
        return
    end
    pcall(function() sock:setopt("socket", "rcvtimeo", 2) end)
    local function ms(st)
        return "M-SEARCH * HTTP/1.1\r\n"
            .. "HOST: 239.255.255.250:1900\r\n"
            .. 'MAN: "ssdp:discover"' .. "\r\n"
            .. "MX: 2\r\n"
            .. "ST: " .. st .. "\r\n\r\n"
    end
    -- 有的电视只响应 MediaRenderer，有的只响应 ssdp:all，各发一次
    pcall(sock.sendto, sock, ms("ssdp:all"), ip, 1900)
    pcall(sock.sendto, sock, ms("urn:schemas-upnp-org:device:MediaRenderer:1"), ip, 1900)

    local loc
    for _ = 1, 8 do
        local data = sock:recvfrom(4096)
        if not data then break end
        loc = data:match("LOCATION:%s*([^\r\n]+)") or data:match("location:%s*([^\r\n]+)")
        if loc and loc ~= "" then break end
    end
    pcall(function() sock:close() end)

    if not loc or loc == "" then
        http.write('{"status":"error","message":"该 IP 没有响应 SSDP（检查电视是否开机、端口 1900 是否被拦截）"}')
        return
    end
    loc = loc:gsub("%s+$", "")
    if not url_is_lan(loc) then
        http.write('{"status":"error","message":"设备返回的 LOCATION 不在本地局域网"}')
        return
    end

    local xml = sys.exec("curl -s --connect-timeout 2 --max-time 4 " .. shell_quote(loc))
    local ctrl, name = parse_upnp_device(xml, loc)
    if not ctrl then
        http.write('{"status":"error","message":"设备描述里没有找到 AVTransport 控制地址"}')
        return
    end
    if not url_is_lan(ctrl) then
        http.write('{"status":"error","message":"该设备返回的控制地址不在本地局域网"}')
        return
    end
    http.write(jsonc.stringify({ status = "success", control_url = ctrl, name = name }))
end

function dlna_cast()
    local http = require "luci.http"
    local sys = require "luci.sys"
    if not dlna_api_guard() then return end
    if not dlna_require_post() then return end
    local control_url = http.formvalue("control_url") or ""
    local video_url = http.formvalue("video_url") or ""
    if control_url == "" or video_url == "" then http.write_json({ status = "error", message = "参数缺失" }); return end
    if not url_is_lan(control_url) then http.write_json({ status = "error", message = "只支持本地局域网设备" }); return end

    local soap1 = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><CurrentURI>%s</CurrentURI><CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>]], video_url)
    local soap2 = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>]]

    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"' -d '%s'", control_url, soap1:gsub("'", "'\\''"))
    local out1 = sys.exec(cmd)
    cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#Play\"' -d '%s'", control_url, soap2:gsub("'", "'\\''"))
    local out2 = sys.exec(cmd)

    if out1 ~= "000" and out2 ~= "000" then
        http.write_json({ status = "success" })
    else
        http.write_json({ status = "error", message = "无法连接设备" })
    end
end

function dlna_cover()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local title = http.formvalue("title") or ""
    local query = title:gsub("%[.-%]", ""):gsub("%(.-%)", ""):gsub("《.-》", ""):gsub("^%d+%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then query = title end
    local cmd = string.format([[curl -s -G -k --connect-timeout 5 --max-time 10 'https://itunes.apple.com/search' --data-urlencode 'term=%s' --data-urlencode 'entity=song' --data-urlencode 'limit=1']], query:gsub("'", "'\\''"))
    local json_str = sys.exec(cmd)
    local artwork = json_str:match('"artworkUrl100":"([^"]+)"')
    if artwork then
        http.prepare_content("application/json")
        http.write_json({ status = "success", url = artwork:gsub("100x100", "600x600") })
    else
        http.prepare_content("application/json")
        http.write_json({ status = "error", message = "未找到封面" })
    end
end

-- 在线歌词：LRCLIB 搜索，优先返回带时间轴的 syncedLyrics
function dlna_lyrics()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")

    local title = (http.formvalue("title") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local artist = (http.formvalue("artist") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local duration = tonumber(http.formvalue("duration")) or 0
    if title == "" then
        http.write('{"status":"error","message":"缺少歌名"}')
        return
    end

    local function lrclib_search(track, who)
        local cmd = "curl -s -k -A 'media-center-lyrics/1.0' -G --connect-timeout 5 --max-time 10 "
            .. shell_quote("https://lrclib.net/api/search")
            .. " --data-urlencode " .. shell_quote("track_name=" .. track)
        if who ~= "" then
            cmd = cmd .. " --data-urlencode " .. shell_quote("artist_name=" .. who)
        end
        cmd = cmd .. " 2>/dev/null"
        local out = sys.exec(cmd)
        local ok, arr = pcall(function() return jsonc.parse(out) end)
        if ok and type(arr) == "table" then return arr end
        return nil
    end

    local function lrclib_pick(arr)
        local best, best_score
        for _, item in ipairs(arr or {}) do
            if type(item) == "table" then
                local synced = item.syncedLyrics or ""
                local plain = item.plainLyrics or ""
                if synced ~= "" or plain ~= "" then
                    local score = 0
                    if synced ~= "" then score = score + 10 end
                    if item.instrumental then score = score - 20 end
                    local d = tonumber(item.duration)
                    if duration > 0 and d then
                        local diff = math.abs(d - duration)
                        if diff <= 2 then score = score + 5
                        elseif diff > 15 then score = score - 5 end
                    end
                    if not best_score or score > best_score then
                        best, best_score = item, score
                    end
                end
            end
        end
        return best
    end

    -- 中文歌曲目录常见“歌名 - 歌手”，也常见“歌手 - 歌名”；
    -- 两种顺序都查一次，避免把歌名当歌手。
    local best = lrclib_pick(lrclib_search(title, artist))
    if not best and artist ~= "" and title ~= "" then
        best = lrclib_pick(lrclib_search(artist, title))
    end

    if not best then
        http.write('{"status":"error","message":"未找到歌词"}')
        return
    end

    http.write(jsonc.stringify({
        status = "success",
        instrumental = best.instrumental and true or false,
        synced = best.syncedLyrics or "",
        plain = best.plainLyrics or "",
        title = best.trackName or title,
        artist = best.artistName or artist,
        album = best.albumName or "",
        duration = tonumber(best.duration) or 0,
    }))
end

-- 把在线歌词保存成音频同目录、同名的 .lrc，下次自动优先读取
function dlna_save_lyrics()
    local http = require "luci.http"
    http.prepare_content("application/json")
    local url = http.formvalue("url") or ""
    local lyrics = http.formvalue("lyrics") or ""
    if url == "" or lyrics == "" then
        http.write_json({ status = "error", message = "参数缺失" })
        return
    end
    if #lyrics > 512 * 1024 then
        http.write_json({ status = "error", message = "歌词内容过大" })
        return
    end
    url = decode_file(url)
    if url:sub(1, 1) ~= "/" then
        http.write_json({ status = "error", message = "只支持本地媒体路径" })
        return
    end
    local path, err = resolve_media(url)
    if not path then
        http.write_json({ status = "error", message = err or "文件不存在" })
        return
    end
    local base = path:gsub("%.[^%.]+$", "")
    local lrc = base .. ".lrc"
    local f = io.open(lrc, "r")
    if f then
        f:close()
        http.write_json({ status = "success", existing = true, path = lrc })
        return
    end
    local out = io.open(lrc, "w")
    if not out then
        http.write_json({ status = "error", message = "无法写入歌词文件（权限？）" })
        return
    end
    out:write(lyrics)
    out:close()
    http.write_json({ status = "success", path = lrc })
end

-- 本地投屏页：由 LuCI 控制器直接输出，避免依赖 880 的静态 location 是否已更新。
-- 页面本身同源，里面的 /dlna/* 请求不会再触发 Chrome 的私网跨域限制。
function dlna_caster()
    local http = require "luci.http"
    http.header("X-Frame-Options", "DENY")
    http.header("Content-Security-Policy", "frame-ancestors 'none'")
    http.header("Cache-Control", "no-store")
    if not ip_is_private(dlna_client_ip()) then
        http.status(403, "Forbidden")
        http.prepare_content("text/html; charset=utf-8")
        http.write('<!DOCTYPE html><html><head><meta charset="utf-8"><title>仅限局域网</title></head>'
            .. '<body style="background:#111;color:#eee;font-family:sans-serif;padding:30px;">'
            .. '<h2>投屏页仅限局域网访问</h2>'
            .. '<p>请在连接本地路由器的手机/电脑上打开投屏页。</p></body></html>')
        return
    end
    http.prepare_content("text/html; charset=utf-8")
    local f = io.open("/www/caster.html", "r")
    if f then
        http.write(f:read("*a"))
        f:close()
    else
        http.write('<!DOCTYPE html><html><head><meta charset="utf-8"><title>caster.html 未部署</title></head>'
            .. '<body style="background:#111;color:#eee;font-family:sans-serif;padding:30px;">'
            .. '<h2>caster.html 未部署</h2>'
            .. '<p>请把 caster.html 复制到本地路由器的 /www/caster.html，然后刷新本页。</p>'
            .. '</body></html>')
    end
end

function dlna_control()
    local http = require "luci.http"
    local sys = require "luci.sys"
    if not dlna_api_guard() then return end
    if not dlna_require_post() then return end
    local action = http.formvalue("action") or ""
    local ctrl_url = http.formvalue("control_url") or ""
    local value = http.formvalue("value") or ""
    if action == "" or ctrl_url == "" then http.write_json({ status = "error", message = "参数缺失" }); return end
    if not url_is_lan(ctrl_url) then http.write_json({ status = "error", message = "只支持本地局域网设备" }); return end

    local target_url = ctrl_url
    local soap = ""
    if action == "pause" then
        soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Pause></s:Body></s:Envelope>]]
    elseif action == "play" then
        soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>]]
    elseif action == "stop" then
        soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Stop></s:Body></s:Envelope>]]
    elseif action == "next" then
        soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Next xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Next></s:Body></s:Envelope>]]
    elseif action == "previous" then
        soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Previous xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Previous></s:Body></s:Envelope>]]
    elseif action == "seek" then
        soap = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>%s</Target></u:Seek></s:Body></s:Envelope>]], value)
    elseif action == "volume" then
        target_url = ctrl_url:gsub("AVTransport", "RenderingControl"):gsub("rendertransport", "rendercontrol")
        soap = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>%s</DesiredVolume></u:SetVolume></s:Body></s:Envelope>]], value)
    end
    if soap == "" then http.write_json({ status = "error", message = "不支持的指令" }); return end

    local soap_action = "urn:schemas-upnp-org:service:AVTransport:1#" .. action:gsub("^%l", string.upper)
    if action == "volume" then soap_action = "urn:schemas-upnp-org:service:RenderingControl:1#SetVolume" end

    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"%s\"' -d '%s'", target_url, soap_action, soap:gsub("'", "'\\''"))
    local out = sys.exec(cmd)

    if out ~= "000" then
        http.write_json({ status = "success", message = "指令已发送" })
    else
        http.write_json({ status = "error", message = "连接失败" })
    end
end

function dlna_get_position()
    local http = require "luci.http"
    local sys = require "luci.sys"
    if not dlna_api_guard() then return end
    local ctrl_url = http.formvalue("control_url") or ""
    if ctrl_url == "" then http.write_json({ status = "error", message = "缺少 control_url" }); return end
    if not url_is_lan(ctrl_url) then http.write_json({ status = "error", message = "只支持本地局域网设备" }); return end

    local soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetPositionInfo></s:Body></s:Envelope>]]
    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 1 --max-time 2 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"' -d '%s'", ctrl_url, soap:gsub("'", "'\\''"))
    local out = sys.exec(cmd)

    local rel_time = out:match("<[rR]elTime>(.-)</[rR]elTime>")
    local track_duration = out:match("<[tT]rackDuration>(.-)</[tT]rackDuration>")
    local transport_state = out:match("<[tT]ransportState>(.-)</[tT]ransportState>")

    if rel_time then
        http.prepare_content("application/json")
        http.write_json({ status = "success", rel_time = rel_time, duration = track_duration, state = transport_state })
    else
        http.prepare_content("application/json")
        http.write_json({ status = "error", message = "设备未返回时间" })
    end
end
