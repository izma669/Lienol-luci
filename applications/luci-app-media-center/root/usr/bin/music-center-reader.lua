#!/usr/bin/lua
-- =============================================================================
-- AirPlay（shairport-sync）元数据读取器
--   读取 /tmp/shairport-sync-metadata FIFO，解析 XML 元数据，
--   写出 /tmp/shairport-now.json 与 /tmp/shairport-cover.jpg 给音乐中心页面用。
-- =============================================================================

local FIFO   = "/tmp/shairport-sync-metadata"
local OUT    = "/tmp/shairport-now.json"
local COVER  = "/tmp/shairport-cover.jpg"
local LOG    = "/tmp/shairport-reader.log"

local state = {
    title = "", artist = "", album = "", lyric = "",
    volume = 0, playing = false,
    snam = "", clip = "",
    has_cover = false, cover_ts = 0, title_locked = false,
    soundcard = "",
}
local cover_buf = nil
local dirty = true

local function log(msg)
    local f = io.open(LOG, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n"); f:close() end
end

local function json_escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", ""):gsub("\t", "\\t")
    return s
end

local function write_state()
    local function b(v) return v and "true" or "false" end
    local out = string.format(
        '{"title":"%s","artist":"%s","album":"%s","lyric":"%s",' ..
        '"volume":%d,"playing":%s,"snam":"%s","clip":"%s",' ..
        '"soundcard":"%s","has_cover":%s,"cover_ts":%d}',
        json_escape(state.title), json_escape(state.artist), json_escape(state.album),
        json_escape(state.lyric), math.floor(state.volume or 0), b(state.playing),
        json_escape(state.snam), json_escape(state.clip), json_escape(state.soundcard),
        b(state.has_cover), math.floor(state.cover_ts or 0))
    local tmp = OUT .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(out)
    f:close()
    os.rename(tmp, OUT)
end

-- base64 解码
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64decode(data)
    data = data:gsub("[^" .. B64:gsub("%+", "%%+") .. "=]", "")
    local out, buf, bits = {}, 0, 0
    for i = 1, #data do
        local c = data:sub(i, i)
        if c == "=" then break end
        local v = B64:find(c, 1, true)
        if v then
            buf = buf * 64 + (v - 1)
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = math.floor(buf / 2 ^ bits) % 256
                out[#out + 1] = string.char(byte)
                buf = buf % (2 ^ bits)   -- 丢弃已输出的高位，避免浮点精度丢失
            end
        end
    end
    return table.concat(out)
end

-- 把 4 位十六进制/ASCII 代码统一成可比较的小写字符串
local function norm_code(s)
    s = tostring(s or ""):gsub("%s+", "")
    if #s == 8 and s:match("^%x+$") then
        local t = {}
        for i = 1, 8, 2 do
            t[#t + 1] = string.char(tonumber(s:sub(i, i + 1), 16) or 0)
        end
        return table.concat(t):lower()
    end
    return s:lower()
end

local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 按歌名 + 歌手在线搜封面（AirPlay 的 PICT 经常是空的）
local function fetch_cover(title, artist)
    title = tostring(title or "")
    artist = tostring(artist or "")
    if title == "" then return false end
    local q = title .. " " .. artist
    local cmd = "curl -s -G --max-time 5 'http://search.kuwo.cn/r.s'"
        .. " --data-urlencode " .. shquote("all=" .. q)
        .. " --data 'ft=music&itemset=web_2013&client=kt&pn=0&rn=1&rformat=json&encoding=utf8'"
    local h = io.popen(cmd)
    local body = h and h:read("*a") or ""
    if h then h:close() end
    local pic = body:match('["\']web_albumpic_short["\']:%s*["\']([^"\']+)["\']')
    if not pic or pic == "" then
        log("cover search miss: " .. q)
        return false
    end
    local path = pic:gsub("^%d+/", "500/")
    local url = "http://img1.kuwo.cn/star/albumcover/" .. path
    os.execute("curl -s --max-time 8 -o " .. COVER .. ".tmp " .. shquote(url) .. " >/dev/null 2>&1")
    local cf = io.open(COVER .. ".tmp", "rb")
    if not cf then return false end
    local sz = cf:seek("end") or 0
    cf:close()
    if sz < 2000 then
        os.remove(COVER .. ".tmp")
        log("cover download too small: " .. sz)
        return false
    end
    os.rename(COVER .. ".tmp", COVER)
    log("cover fetched online: " .. sz .. " bytes")
    return true
end
local function handle_item(item)
    local typ = item:match("<type>(.-)</type>") or ""
    local code = norm_code(item:match("<code>(.-)</code>") or "")
    local len = tonumber(item:match("<length>(.-)</length>") or "") or 0
    local data = item:match('<data encoding="base64">(.-)</data>')
    if not data then data = item:match("<data>(.-)</data>") end

    -- 调试开关：存在 /tmp/shairport-debug 时记录所有元数据类型
    if io.open("/tmp/shairport-debug", "r") then
        local dbg = io.open("/tmp/shairport-codes.log", "a")
        if dbg then
            local pv = ""
            if data and #data > 0 then
                local dec = b64decode(data)
                pv = (dec ~= "" and dec or data):gsub("[\r\n]+", " "):sub(1, 40)
            end
            dbg:write(os.date("%H:%M:%S"), " ", code, " len=", tostring(len), " | ", pv, "\n")
            dbg:close()
        end
    end

    if code == "pict" then
        -- 封面：可能是二进制（base64）也可能是空（表示清除）
        if data and #data > 0 then
            local bin = b64decode(data)
            if #bin > 100 then
                local f = io.open(COVER, "wb")
                if f then f:write(bin); f:close() end
                state.has_cover = true
                state.cover_ts = os.time()
                dirty = true
                log("cover received: " .. #bin .. " bytes")
            end
        end
        -- 空 PICT（很多客户端换歌时发）不清除已有封面
        return
    end


    if not data or #data == 0 then
        -- 无数据的控制类消息
        if code == "pbeg" or code == "mdst" or code == "prsm" then state.playing = true; dirty = true
        elseif code == "pend" or code == "pfls" then
            state.playing = false; dirty = true
            -- 不主动清封面：QQ 音乐换歌时不会再发 PICT，清了就一直是空的
        elseif code == "prsm" then state.playing = true; dirty = true
        end
        return
    end

    local text = b64decode(data)
    if text == "" then text = data end

    if code == "minm" then
        -- QQ 音乐会把这个字段当歌词发：锁定歌名后，后续内容当作歌词
        if state.title_locked then
            -- 客户端会把这个字段在歌名和歌词行之间来回发，只有真正的歌词才保留
            local lt = text:match("^(.-)%s+—%s+.+$")
            if text ~= state.title and lt ~= state.title then state.lyric = text end
        else
            state.title = text
        end
        state.playing = true; dirty = true
    elseif code == "asar" then
        -- 形如「歌名 — 歌手」时直接拆开，这类客户端不会单独给歌名
        local t1, a1 = text:match("^(.-)%s+—%s+(.+)$")
        if not t1 then t1, a1 = text:match("^(.-)%s+%-%s+(.+)$") end
        if t1 and a1 and #t1 > 0 and #a1 > 0 then
            local changed = (t1 ~= state.title)
            state.title = t1
            state.artist = a1
            state.title_locked = true
            if changed then
                state.lyric = ""
                state.has_cover = false
                state.cover_ts = os.time()
            end
        else
            state.artist = text
            state.title_locked = false
        end
        dirty = true
    elseif code == "asal" then state.album = text; dirty = true
    elseif code == "snam" then state.snam = text; dirty = true
    elseif code == "snua" then state.snam = text; dirty = true
    elseif code == "clip" then state.clip = text; dirty = true
    elseif code == "pvol" or code == "pvlm" then
        local db = tonumber(text:match("(-?[%d%.]+)"))
        if db then
            if db <= -144 then
                state.volume = 0
            else
                local pct = (db + 30) / 30 * 100
                if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
                state.volume = math.floor(pct + 0.5)
            end
            dirty = true
        end
    elseif code == "pbeg" then state.playing = true; dirty = true
    elseif code == "pend" or code == "pfls" then state.playing = false; dirty = true
    elseif code == "prsm" then state.playing = true; dirty = true
    end
end

-- 启动时沿用上一次的曲目信息（重启后不用等手机下一次推送）
do
    local f = io.open(OUT, "r")
    if f then
        local raw = f:read("*a") or ""
        f:close()
        local function get(k)
            local v = raw:match('"' .. k .. '":"(.-)"')
            if not v then return "" end
            return v:gsub('\\"', '"'):gsub("\\\\", "\\"):gsub("\\n", "\n")
        end
        state.title = get("title")
        state.artist = get("artist")
        state.album = get("album")
        state.snam = get("snam")
        state.clip = get("clip")
        local pv = raw:match('"playing":(true|false)')
        if pv == "true" then state.playing = true end
        local vv = raw:match('"volume":(%d+)')
        if vv then state.volume = tonumber(vv) or 0 end
        log("restore last track: " .. state.title .. " playing=" .. tostring(state.playing))
    end
end


-- 启动时清空封面状态：只有发送端真的发了才显示
state.has_cover = false
state.cover_ts = 0
write_state()

-- 主循环：持续读 FIFO
log("reader started")
local buf = ""
while true do
    local f = io.open(FIFO, "rb")
    if not f then
        log("open fifo failed, retry")
        os.execute("sleep 2")
    else
        log("fifo opened")
        while true do
            local chunk = f:read(4096)
            if not chunk or chunk == "" then break end
            buf = buf .. chunk
            while true do
                local s, e = buf:find("<item>", 1, true), buf:find("</item>", 1, true)
                if not s or not e then break end
                local item = buf:sub(s, e + 6)
                buf = buf:sub(e + 7)
                local ok, err = pcall(handle_item, item)
                if not ok then log("parse error: " .. tostring(err)) end
                if dirty then dirty = false; write_state() end
            end
            -- 防止异常数据无限增长
            if #buf > 65536 then buf = buf:sub(-8192) end
        end
        f:close()
        log("fifo closed, reopen")
        os.execute("sleep 1")
    end
end