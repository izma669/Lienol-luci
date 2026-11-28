#!/usr/bin/lua
-- SSDP 广播代理：把公网 DLNA 服务器“广播”到本机局域网
-- 配置 /etc/config/ssdp-relay：
--   config relay 'main'
--       option enabled '1'
--   config server 'remote'
--       option name '远程DLNA'
--       option location 'http://host:8200/rootDesc.xml'
--       option interval '600'

local nixio = require "nixio"

local MULTI = "239.255.255.250"
local PORT = 1900
local SERVER_HDR = "Linux/4.14 UPnP/1.0 DLNADOC/1.50"

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function sh(cmd)
    local f = io.popen(cmd)
    if not f then return "" end
    local v = f:read("*a") or ""
    f:close()
    return v
end

local function uci_get(sec, opt)
    return (sh("uci -q get ssdp-relay." .. sec .. "." .. opt .. " 2>/dev/null"):gsub("%s+$", ""))
end

local function uci_show(section_type)
    local out = {}
    for line in sh("uci -q show ssdp-relay 2>/dev/null"):gmatch("[^\n]+") do
        local t, k, v = line:match("^ssdp%-relay%.([^.]+)%.([^=]+)=(.*)$")
        if t and k then
            local sname, opt = t, k
            local optname = opt:gsub("^%d+$", "")
        end
    end
    return out
end

-- 读取配置：优先 minidlna.config.relay_*，兼容旧的 /etc/config/ssdp-relay
local function mget(opt, default)
    local f = io.popen("uci -q get minidlna.config." .. opt .. " 2>/dev/null")
    if not f then return default end
    local v = f:read("*a") or ""
    f:close()
    v = v:gsub("%s+$", "")
    if v == "" then return default end
    return v
end

local function load_servers()
    local list = {}

    if mget("relay_enabled", "0") == "1" then
        local url = mget("relay_url", "")
        if url ~= "" then
            list[#list + 1] = {
                name = "remote",
                location = url,
                interval = 600,
                local_port = tonumber(mget("relay_port", "0")) or 0,
            }
        end
    end

    -- 兼容旧的独立配置
    if #list == 0 then
        local raw = sh("uci -q show ssdp-relay 2>/dev/null")
        for line in raw:gmatch("[^\n]+") do
            local sec, typ = line:match("^ssdp%-relay%.([%w_]+)=(%w+)$")
            if sec and typ == "server" then
                local loc = uci_get(sec, "location")
                if loc ~= "" then
                    list[#list + 1] = {
                        name = uci_get(sec, "name"),
                        location = loc,
                        interval = tonumber(uci_get(sec, "interval")) or 600,
                        local_port = tonumber(uci_get(sec, "local_port")) or 0,
                    }
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.location < b.location end)
    return list
end

local function http_get(url, timeout)
    local body = sh("curl -fsSL --connect-timeout 5 --max-time " .. tostring(timeout or 10) .. " " .. shq(url) .. " 2>/dev/null")
    if body == "" then return nil end
    return body
end

local function probe(srv)
    local body = http_get(srv.location, 10)
    if not body then return false end
    local udn = body:match("<UDN>([^<]+)</UDN>") or body:match("<UDN[^>]*>([^<]+)</UDN>")
    if not udn or udn == "" then return false end
    srv.udn = udn
    srv.uuid = udn:gsub("^uuid:", "")
    srv.devicetype = body:match("<deviceType>([^<]+)</deviceType>") or "urn:schemas-upnp-org:device:MediaServer:1"
    srv.friendly = body:match("<friendlyName>([^<]+)</friendlyName>") or srv.name
    srv.types = {
        "upnp:rootdevice",
        "uuid:" .. srv.uuid,
        srv.devicetype,
    }

    -- 记录远端 IP（用于端口映射）
    local rip = sh("curl -s -o /dev/null -w '%{remote_ip}' --max-time 5 " .. shq(srv.location) .. " 2>/dev/null")
    rip = (rip or ""):gsub("%s+$", "")
    if rip ~= "" then srv.remote_ip = rip end
    return true
end

-- 把 内网IP:local_port 映射到 远端:8200（用独立链，避免重复规则）
local function install_dnat(srv, lan_ip)
    if not srv.local_port or srv.local_port == 0 or not srv.remote_ip then return end
    local lp = tostring(srv.local_port)
    local dst = srv.remote_ip .. ":8200"
    local chain = "SSDPRELAY"

    sh("iptables -t nat -N " .. chain .. " 2>/dev/null")
    sh("iptables -t nat -F " .. chain .. " 2>/dev/null")

    for _, parent in ipairs({ "PREROUTING", "OUTPUT" }) do
        local has = sh("iptables -t nat -S " .. parent .. " 2>/dev/null | grep -c -- '-j " .. chain .. "'")
        if (has:gsub("%s", "") == "0") then
            sh("iptables -t nat -A " .. parent .. " -j " .. chain .. " 2>/dev/null")
        end
    end

    sh("iptables -t nat -A " .. chain .. " -d " .. lan_ip .. " -p tcp --dport " .. lp ..
       " -j DNAT --to-destination " .. dst .. " 2>/dev/null")
    sh("iptables -t nat -C POSTROUTING -p tcp -d " .. srv.remote_ip ..
       " --dport 8200 -j MASQUERADE 2>/dev/null || " ..
       "iptables -t nat -A POSTROUTING -p tcp -d " .. srv.remote_ip ..
       " --dport 8200 -j MASQUERADE 2>/dev/null")

    srv.announce = "http://" .. lan_ip .. ":" .. lp .. "/rootDesc.xml"
    local lg = io.open("/tmp/ssdp-relay.log", "a")
    if lg then
        lg:write(string.format("%s 端口映射 %s:%s -> %s\n", os.date("%F %T"), lan_ip, lp, dst))
        lg:close()
    end
end

local function send_notify(sock, srv, nts)
    for _, nt in ipairs(srv.types) do
        local msg = table.concat({
            "NOTIFY * HTTP/1.1",
            "HOST: " .. MULTI .. ":" .. PORT,
            "CACHE-CONTROL: max-age=1800",
            "LOCATION: " .. (srv.announce or srv.location),
            "NT: " .. nt,
            "NTS: " .. nts,
            "SERVER: " .. SERVER_HDR,
            "USN: " .. srv.udn .. "::" .. nt,
            "",
            "",
        }, "\r\n")
        sock:sendto(msg, MULTI, PORT)
    end
end

local function http_date()
    return os.date("!%a, %d %b %Y %H:%M:%S GMT")
end

local function reply_search(sock, srv, st, ip, port)

    if st ~= "ssdp:all" and st ~= srv.types[1] and st ~= srv.types[2] and st ~= srv.types[3] then
        return false
    end
    local answers = {}
    if st == "ssdp:all" then
        answers = srv.types
    else
        answers = { st }
    end
    local sent = false
    for _, a in ipairs(answers) do
        local msg = table.concat({
            "HTTP/1.1 200 OK",
            "CACHE-CONTROL: max-age=1800",
            "DATE: " .. http_date(),
            "EXT:",
            "LOCATION: " .. (srv.announce or srv.location),
            "SERVER: " .. SERVER_HDR,
            "ST: " .. a,
            "USN: " .. srv.udn .. "::" .. a,
            "",
            "",
        }, "\r\n")
        local n = sock:sendto(msg, ip, port)
        if n then
            local lg = io.open("/tmp/ssdp-relay.log", "a")
            if lg then lg:write(os.date("%F %T").." 应答 "..a.." -> "..tostring(ip)..":"..tostring(port).."\n"); lg:close() end
        end
        sent = true
    end
    return sent
end

local function bye()
    local servers = load_servers()
    if #servers == 0 then return end
    local sock = nixio.socket("inet", "dgram")
    sock:setsockopt("ip", "multicast_ttl", 2)
    local lip = (sh("ip -4 addr show dev br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1"):gsub("%s+$", ""))
    if lip ~= "" then pcall(function() sock:setsockopt("ip", "multicast_if", lip) end) end
    for _, srv in ipairs(servers) do
        probe(srv)
        send_notify(sock, srv, "ssdp:byebye")
    end
    sock:close()
end

local function main()
    local servers = load_servers()
    local lf0 = io.open("/tmp/ssdp-relay.log","a")
    if lf0 then lf0:write(os.date("%F %T").." 启动，服务器数="..#servers.."\n"); lf0:close() end
    if #servers == 0 then
        os.exit(0)
    end

    for _, srv in ipairs(servers) do
        if not probe(srv) then
            -- 远端不可达时退出，让 procd 稍后重启
            os.exit(1)
        end
    end

    -- 取内网接口地址（默认 br-lan），多播必须从它发出
    local lan_ip = (sh("ip -4 addr show dev br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1"):gsub("%s+$", ""))
    if lan_ip == "" then lan_ip = (sh("ip -4 addr show 2>/dev/null | awk '/inet /&&!/127.0.0.1/{print $2}' | cut -d/ -f1 | head -1"):gsub("%s+$", "")) end

    for _, srv in ipairs(servers) do
        install_dnat(srv, lan_ip)
    end

    local sock = nixio.socket("inet", "dgram")
    sock:setsockopt("socket", "reuseaddr", 1)
    sock:setsockopt("ip", "multicast_ttl", 2)
    sock:setsockopt("ip", "multicast_loop", 1)
    if lan_ip ~= "" then
        pcall(function() sock:setsockopt("ip", "multicast_if", lan_ip) end)
    end
    sock:setsockopt("ip", "add_membership", MULTI)
    sock:bind("0.0.0.0", PORT)
    sock:setblocking(false)


    -- 启动即广播一次
    for _, srv in ipairs(servers) do send_notify(sock, srv, "ssdp:alive") end

    local last = os.time()
    local smallest = 600
    for _, srv in ipairs(servers) do
        if srv.interval < smallest then smallest = srv.interval end
    end

    while true do
        local data, ip, port = sock:recvfrom(4096)
        while data do

            if data:sub(1, 8):upper() == "M-SEARCH" then
                local st = data:match("\r\n[Ss][Tt]:%s*([^\r\n]+)") or data:match("^[Ss][Tt]:%s*([^\r\n]+)")
                if st then
                    st = st:gsub("%s+$", "")
                    do
                        local lg = io.open("/tmp/ssdp-relay.log", "a")
                        if lg then
                            lg:write(string.format("%s 搜索 %s 来自 %s (UA=%s)\n", os.date("%F %T"),
                                st, tostring(ip), tostring(data:match("USER%-AGENT:%s*([^\r\n]+)"))))
                            lg:close()
                        end
                    end
                    for _, srv in ipairs(servers) do
                        reply_search(sock, srv, st, ip, port)
                    end
                end
            end
            data, ip, port = sock:recvfrom(4096)
        end
        nixio.nanosleep(0, 200000000)

        if os.time() - last >= smallest then
            for _, srv in ipairs(servers) do send_notify(sock, srv, "ssdp:alive") end
            last = os.time()
            -- 顺带刷新一次 description（IP/端口可能变）
            for _, srv in ipairs(servers) do probe(srv) end
        end
    end
end

if arg[1] == "--bye" then bye() else main() end
