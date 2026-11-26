-- Licensed to the public under the Apache License 2.0.

module("luci.controller.ksmbd", package.seeall)

local DEFAULT_LOG = "/mnt/mmcblk0p1/log/ksmbd.log"
local LOGPID = "/var/run/ksmbd-log.pid"

local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function get_uci()
	return require("luci.model.uci").cursor()
end

local function log_path()
	local p = get_uci():get("ksmbd", "@globals[0]", "log_path")
	if not p or p == "" then p = DEFAULT_LOG end
	return p
end

local function log_enabled()
	return get_uci():get("ksmbd", "@globals[0]", "log_enabled") == "1"
end

local function log_running()
	return (require("luci.sys").call("start-stop-daemon -K -q -t -p " .. LOGPID) == 0)
end

local function log_start()
	local sys = require "luci.sys"
	local path = log_path()
	sys.call("start-stop-daemon -K -q -p " .. LOGPID .. " -s TERM 2>/dev/null; rm -f " .. LOGPID)
	sys.call("mkdir -p " .. shq(path:match("^(.*)/[^/]*$") or "/tmp"))
	sys.call("start-stop-daemon -S -q -b -x /sbin/logread -- -f -e ksmbd -F " .. shq(path) .. " -p " .. LOGPID)
end

local function log_stop()
	require("luci.sys").call("start-stop-daemon -K -q -p " .. LOGPID .. " -s TERM 2>/dev/null; rm -f " .. LOGPID)
end

local function log_trim(path)
	local fs = require "nixio.fs"
	local st = fs.stat(path)
	if not st or not st.size or st.size <= 1048576 then return end
	local rf = io.open(path, "r")
	local data = rf and (rf:read("*a") or "") or ""
	if rf then rf:close() end
	local wf = io.open(path, "w")
	if wf then wf:write(data:sub(-262144)); wf:close() end
end

function index()
	if not nixio.fs.access("/etc/config/ksmbd") then
		return
	end

	entry({"admin","nas"},firstchild(),"NAS",44).dependent=false

	local page

	page = entry({"admin", "nas", "ksmbd"}, cbi("ksmbd"), _("Network Shares (KSMBD)"))
	page.dependent = true

	entry({"admin", "nas", "ksmbd", "status"}, call("action_status")).leaf = true
	entry({"admin", "nas", "ksmbd", "logdata"}, call("action_logdata")).leaf = true
	entry({"admin", "nas", "ksmbd", "logtoggle"}, call("action_logtoggle")).leaf = true
	entry({"admin", "nas", "ksmbd", "logclear"}, call("action_logclear")).leaf = true
end

function action_status()
	local sys = require "luci.sys"
	local pids = (sys.exec("pidof ksmbd.mountd 2>/dev/null") or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local n = 0
	for _ in pids:gmatch("%d+") do n = n + 1 end
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		running = (pids ~= ""),
		pids = pids,
		procs = n,
		time = os.date("%H:%M:%S")
	})
end

function action_logdata()
	local fs = require "nixio.fs"
	local path = log_path()
	log_trim(path)
	local lines = {}
	if fs.access(path) then
		local f = io.open(path, "r")
		if f then
			local data = f:read("*a") or ""
			f:close()
			local all = {}
			for l in data:gmatch("[^\r\n]+") do all[#all + 1] = l end
			for i = #all, 1, -1 do
				table.insert(lines, 1, all[i])
				if #lines >= 300 then break end
			end
		end
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		enabled = log_enabled(),
		running = log_running(),
		path = path,
		lines = lines
	})
end

function action_logtoggle()
	local uci = require("luci.model.uci").cursor()
	local on = (luci.http.formvalue("enabled") == "1")
	local path = luci.http.formvalue("path")
	uci:set("ksmbd", "@globals[0]", "log_enabled", on and "1" or "0")
	if path and path ~= "" then
		uci:set("ksmbd", "@globals[0]", "log_path", path)
	end
	uci:commit("ksmbd")
	if on then log_start() else log_stop() end
	luci.http.prepare_content("application/json")
	luci.http.write_json({ enabled = on, running = log_running(), path = log_path() })
end

function action_logclear()
	local fs = require "nixio.fs"
	fs.writefile(log_path(), "")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ ok = true })
end
