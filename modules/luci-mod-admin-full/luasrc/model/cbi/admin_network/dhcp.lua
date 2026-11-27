-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Licensed to the public under the Apache License 2.0.

local ipc = require "luci.ip"
local o
require "luci.util"
local sys = require "luci.sys"

m = Map("dhcp", translate("DHCP"))

s = m:section(TypedSection, "dnsmasq", "")
s.anonymous = true
s.addremove = false

s:tab("general", translate("General Settings"))
s:tab("devices", translate("Devices &amp; Ports"))
s:tab("logging", translate("Log"))
s:tab("files", translate("File"))
s:tab("tftp", translate("TFTP Settings"))

s:taboption("general", Flag, "authoritative",
	translate("Authoritative"),
	translate("This is the only <abbr title=\"Dynamic Host Configuration Protocol\">DHCP</" ..
		"abbr> in the local network"))

s:taboption("general", Value, "domain",
	translate("Local domain"),
	translate("Local domain suffix appended to DHCP names and hosts file entries"))

se = s:taboption("general", Flag, "sequential_ip",
	translate("Allocate IP sequentially"),
	translate("Allocate IP addresses sequentially, starting from the lowest available address"))
se.optional = true

lm = s:taboption("general", Value, "dhcpleasemax",
	translate("<abbr title=\"maximal\">Max.</abbr> <abbr title=\"Dynamic Host Configuration " ..
		"Protocol\">DHCP</abbr> leases"),
	translate("Maximum allowed number of active DHCP leases"))

lm.optional = true
lm.datatype = "uinteger"
lm.placeholder = translate("unlimited")

o = s:taboption("general", Flag, "address_as_local",
	translate("Resolve addresses locally"),
	translate("Never send queries for FQDNs in the Address option to an upstream resolver."))
o.optional = true


o = s:taboption("devices", Flag, "nonwildcard",
	translate("Non-wildcard"),
	translate("Bind only to specific interfaces rather than wildcard address."))
o.optional = false
o.rmempty = false

o = s:taboption("devices", DynamicList, "interface",
	translate("Listen Interfaces"),
	translate("Limit listening to these interfaces, and loopback."))
o.optional = true
o:depends("nonwildcard", true)

o = s:taboption("devices", DynamicList, "listen_address",
	translate("Listen addresses"),
	translate("Listen only on the specified addresses."))
o.optional = true
o:depends("nonwildcard", true)

o = s:taboption("devices", DynamicList, "notinterface",
	translate("Exclude interfaces"),
	translate("Prevent listening on these interfaces."))
o.optional = true
o:depends("nonwildcard", true)


o = s:taboption("logging", Flag, "logdhcp",
	translate("Extra DHCP logging"),
	translate("Log all options sent to DHCP clients and the tags used to determine them."))
o.optional = true

o = s:taboption("logging", Value, "logfacility",
	translate("Log facility"),
	translate("Set log class/facility for syslog entries."))
o.optional = true
o:value('KERN')
o:value('USER')
o:value('MAIL')
o:value('DAEMON')
o:value('AUTH')
o:value('LPR')
o:value('NEWS')
o:value('UUCP')
o:value('CRON')
o:value('LOCAL0')
o:value('LOCAL1')
o:value('LOCAL2')
o:value('LOCAL3')
o:value('LOCAL4')
o:value('LOCAL5')
o:value('LOCAL6')
o:value('LOCAL7')
o:value('-', 'stderr')

qu = s:taboption("logging", Flag, "quietdhcp",
	translate("Suppress logging"),
	translate("Suppress logging of the routine operation of these protocols"))
qu.optional = true
qu:depends("logdhcp", false)


s:taboption("files", Flag, "readethers",
	translate("Use <code>/etc/ethers</code>"),
	translate("Read <code>/etc/ethers</code> to configure the <abbr title=\"Dynamic Host " ..
		"Configuration Protocol\">DHCP</abbr>-Server"))

s:taboption("files", Value, "leasefile",
	translate("Leasefile"),
	translate("file where given <abbr title=\"Dynamic Host Configuration Protocol\">DHCP</" ..
		"abbr>-leases will be stored"))


s:taboption("tftp", Flag, "enable_tftp",
	translate("Enable TFTP server")).optional = true

tr = s:taboption("tftp", Value, "tftp_root",
	translate("TFTP server root"),
	translate("Root directory for files served via TFTP"))

tr.optional = true
tr:depends("enable_tftp", "1")
tr.placeholder = "/"

-- PXE boot files: stored directly in /etc/dnsmasq.conf (no helper scripts)
local PXE_FILE = "/etc/dnsmasq.conf"
local PXE_BEGIN = "# BEGIN LuCI PXE Boot"
local PXE_END = "# END LuCI PXE Boot"

local function pxe_trim(s)
	return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function pxe_read()
	local f = io.open(PXE_FILE, "r")
	if not f then return "" end
	local d = f:read("*a")
	f:close()
	return d or ""
end

local function pxe_save(path, data)
	local f = io.open(path, "w")
	if f then f:write(data); f:close() end
end

local function pxe_first_match(text, ...)
	local pats = {...}
	for line in text:gmatch("[^\r\n]+") do
		for _, pat in ipairs(pats) do
			local v = line:match(pat)
			if v then return pxe_trim(v) end
		end
	end
	return ""
end

local function pxe_parse(text)
	return {
		pxe_bios   = pxe_first_match(text, "^dhcp%-boot=.*tag:bios,(.+)$"),
		pxe_uefi64 = pxe_first_match(text, "^dhcp%-boot=.*tag:efi64,(.+)$", "^dhcp%-boot=.*tag:!bios,(.+)$"),
		pxe_uefi32 = pxe_first_match(text, "^dhcp%-boot=.*tag:efi32,(.+)$"),
		pxe_arm64  = pxe_first_match(text, "^dhcp%-boot=.*tag:arm64,(.+)$"),
		pxe_ipxe4  = pxe_first_match(text, "^dhcp%-boot=tag:ipxe,(.+)$"),
		pxe_ipxe6  = pxe_first_match(text, "^dhcp%-option=option6:59,(.+)$", "^dhcp%-option=option6:bootfile%-url,(.+)$"),
	}
end

local pxe_values = pxe_parse(pxe_read())

local function pxe_starts(line, prefix)
	return line:sub(1, #prefix) == prefix
end

local function pxe_block(v)
	local out = { PXE_BEGIN }
	local function add(s) out[#out+1] = s end

	if v.pxe_bios ~= "" then
		add("dhcp-match=set:bios,option:client-arch,0")
		add("dhcp-boot=tag:!ipxe,tag:bios," .. v.pxe_bios)
	end
	if v.pxe_uefi64 ~= "" then
		add("dhcp-match=set:efi64,option:client-arch,7")
		add("dhcp-match=set:efi64,option:client-arch,9")
		add("dhcp-boot=tag:!ipxe,tag:efi64," .. v.pxe_uefi64)
	end
	if v.pxe_uefi32 ~= "" then
		add("dhcp-match=set:efi32,option:client-arch,6")
		add("dhcp-boot=tag:!ipxe,tag:efi32," .. v.pxe_uefi32)
	end
	if v.pxe_arm64 ~= "" then
		add("dhcp-match=set:arm64,option:client-arch,11")
		add("dhcp-boot=tag:!ipxe,tag:arm64," .. v.pxe_arm64)
	end
	if v.pxe_ipxe4 ~= "" then
		add("dhcp-match=set:ipxe,175")
		add("dhcp-boot=tag:ipxe," .. v.pxe_ipxe4)
	end
	if v.pxe_ipxe6 ~= "" then
		add("dhcp-option=option6:59," .. v.pxe_ipxe6)
	end
	add(PXE_END)
	return out
end

local function pxe_write(v)
	local text = pxe_read()
	pxe_save(PXE_FILE .. ".luci.bak", text)

	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		lines[#lines+1] = line
	end

	local out = {}
	local inblock = false
	local insert_at

	for _, line in ipairs(lines) do
		if pxe_starts(line, PXE_BEGIN) then
			inblock = true
		elseif pxe_starts(line, PXE_END) then
			inblock = false
		elseif not inblock then
			local is_pxe =
				pxe_starts(line, "dhcp-match=set:bios,") or
				pxe_starts(line, "dhcp-match=set:ipxe,") or
				pxe_starts(line, "dhcp-match=set:efi64,") or
				pxe_starts(line, "dhcp-match=set:efi32,") or
				pxe_starts(line, "dhcp-match=set:arm64,") or
				line:match("^dhcp%-boot=.*tag:bios,") or
				line:match("^dhcp%-boot=.*tag:efi64,") or
				line:match("^dhcp%-boot=.*tag:efi32,") or
				line:match("^dhcp%-boot=.*tag:arm64,") or
				line:match("^dhcp%-boot=.*tag:!bios,") or
				line:match("^dhcp%-boot=.*tag:ipxe,") or
				pxe_starts(line, "dhcp-option=option6:59,") or
				pxe_starts(line, "dhcp-option=option6:bootfile-url,") or
				line:match("^#%s*ipxe boot config")
			if is_pxe then
				if not insert_at then insert_at = #out + 1 end
			else
				out[#out+1] = line
			end
		end
	end

	if not insert_at then
		for i, line in ipairs(out) do
			if pxe_starts(line, "srv-host=") or pxe_starts(line, "conf-dir=") then
				insert_at = i
				break
			end
		end
	end
	if not insert_at then insert_at = #out + 1 end

	local block = pxe_block(v)
	for i = #block, 1, -1 do
		table.insert(out, insert_at, block[i])
	end
	pxe_save(PXE_FILE, table.concat(out, "\n") .. "\n")
	return true
end

local function is_lan_iface(name)
	name = name or ""
	return name == "br-lan" or name == "lan" or name == "eth0.1"
		or name:match("^br%-lan%.") ~= nil
end

local function detect_ipv6()
	local list, seen = {}, {}
	local ok, nixio = pcall(require, "nixio")
	if not ok or not nixio.getifaddrs then return list end
	local ifs = nixio.getifaddrs() or {}
	for _, a in ipairs(ifs) do
		local ip = a.addr
		if is_lan_iface(a.name) and (a.family == "inet6" or a.family == 10)
			and ip and ip ~= "::1"
			and not ip:match("^fe80:") and not ip:match("^::ffff:") then
			ip = ip:match("^[^%%]+") or ip
			if not seen[ip] then
				seen[ip] = true
				list[#list+1] = ip
			end
		end
	end
	table.sort(list)
	return list
end

local function js_quote(s)
	return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", "\\n") .. '"'
end

local function html_escape(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function list_tftp_files()
	local list = {}
	local ok, nixio = pcall(require, "nixio")
	if not ok or not nixio.fs then return list end
	local dir = "/mnt/mmcblk0p1/tftp/"
	local okdir, iter = pcall(nixio.fs.dir, dir)
	if not okdir or not iter then return list end
	for name in iter do
		local st = nixio.fs.stat(dir .. name)
		if st and st.type == "reg" then list[#list+1] = name end
	end
	table.sort(list)
	return list
end

local function build_ipv6_picker(addr, files)
	local opts = {}
	for i = 1, #files do
		if addr and addr ~= "" then
			local u = "tftp://[" .. addr .. "]/" .. files[i]
			opts[i] = '<option value="' .. html_escape(u) .. '">' .. html_escape(u) .. '</option>'
		end
	end
	local addrjs = js_quote(addr or "")
	return [[
<style>
#pxe6-line { display:flex; align-items:center; gap:6px; }
#pxe6-line span { white-space:nowrap; }
#pxe6-select { flex:1; min-width:0; width:auto; max-width:100%; padding:3px 4px; }
input[name$="pxe_ipxe6"] { width:620px !important; max-width:100%; }
</style>
<div id="pxe6-line" style="margin:2px 0;">
	<span>选择菜单文件以生成地址：</span>
	<select id="pxe6-select" class="cbi-input-select">
		<option value="">-- 请选择 --</option>]] .. table.concat(opts, "") .. [[
	</select>
</div>
<script type="text/javascript">
(function(){
	var addr = ]] .. addrjs .. [[;
	function toast() {
		if (document.cookie.indexOf('pxe_saved=1') < 0) return;
		var d = document.createElement('div');
		d.textContent = '写入参数成功';
		d.style.cssText = 'position:fixed;top:18px;right:18px;z-index:999999;background:#1a7f37;color:#fff;padding:10px 16px;border-radius:6px;font-weight:bold;box-shadow:0 2px 8px rgba(0,0,0,.2);';
		document.body.appendChild(d);
		document.cookie = 'pxe_saved=1; Path=/; Max-Age=0';
		setTimeout(function(){ d.style.transition='opacity .4s'; d.style.opacity='0'; setTimeout(function(){ d.remove(); },450); }, 3000);
	}
	function input() { return document.querySelector('input[name$="pxe_ipxe6"]'); }
	function attach() {
		var i = input();
		var s = document.getElementById('pxe6-select');
		if (!i || !s || i.getAttribute('data-pxe6') === '1') return;
		i.setAttribute('data-pxe6', '1');
		if (!addr) { s.disabled = true; return; }
		for (var n = 0; n < s.options.length; n++) {
			if (s.options[n].value === i.value) { s.selectedIndex = n; break; }
		}
		s.onchange = function() {
			if (!s.value) return;
			i.value = s.value;
			i.dispatchEvent(new Event('change', {bubbles:true}));
		};
	}
	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', attach);
	else attach();
	setTimeout(attach, 300);
	setTimeout(attach, 900);
	toast();
})();
</script>
]]
end

local function pxe_option(name, title, desc, default, placeholder)
	local opt = s:taboption("tftp", Value, name, title, desc)
	opt.optional = true
	opt.rmempty = true
	opt.default = default
	opt.placeholder = placeholder or default
	opt.load = function(self, section)
		return pxe_parse(pxe_read())[name] or self.default or ""
	end
	opt.cfgvalue = function(self, section)
		return pxe_parse(pxe_read())[name] or self.default or ""
	end
	opt.write = function(self, section, value)
		pxe_values = pxe_parse(pxe_read())
		pxe_values[name] = pxe_trim(value)
		pxe_write(pxe_values)
		return true
	end
	opt.remove = function(self, section)
		pxe_values = pxe_parse(pxe_read())
		pxe_values[name] = ""
		pxe_write(pxe_values)
		return true
	end
	return opt
end

s:taboption("tftp", DummyValue, "_pxe_note", '<span style="color:#b35c00;font-weight:bold">PXE 多架构启动文件</span>',
	"以下选项直接写入 /etc/dnsmasq.conf，保存后自动重启 dnsmasq。")

pxe_option("pxe_bios", "传统 BIOS 启动文件",
	"相对于 TFTP 根目录，例如 gpxelinux.0；也可写完整 URL。", "gpxelinux.0")
pxe_option("pxe_uefi64", "UEFI x64 启动文件",
	"例如 ipxe.efi。", "ipxe.efi")
pxe_option("pxe_uefi32", "UEFI x32 启动文件",
	"例如 ipxe32.efi；留空不配置。", "", "ipxe32.efi")
pxe_option("pxe_arm64", "UEFI ARM64 启动文件",
	"例如 ipxe-arm64.efi；留空不配置。", "", "ipxe-arm64.efi")
-- The iPXE menu is the second-stage download. These fields accept
-- a plain filename (relative to tftp-root) or a full http(s)/tftp URL.
s:taboption("tftp", DummyValue, "_pxe_menu_note", '<span style="color:#b35c00;font-weight:bold">启动菜单文件</span>',
	"iPXE IPv4/IPv6 启动菜单是第二级下载文件，可填完整 URL 指向其它 HTTP/TFTP 服务器，不限于本机 TFTP 根目录。")

pxe_option("pxe_ipxe4", "iPXE IPv4 启动菜单",
	"第二级菜单文件；可填 autoexec.ipxe，也可填 http://、https:// 或 tftp:// 完整 URL 指向其它服务器。", "autoexec.ipxe")

local ipv6_addrs = detect_ipv6()
local ipv6_example = "tftp://[IPv6地址]/autoexecipv6.ipxe"
local ipv6_hint
if #ipv6_addrs > 0 then
	ipv6_example = "tftp://[" .. ipv6_addrs[1] .. "]/autoexecipv6.ipxe"
	ipv6_hint = '检测到的LAN IPv6 地址：<span style="color:#1a7f37;font-weight:bold">' .. table.concat(ipv6_addrs, ", ") .. '</span>'
else
	ipv6_hint = '未检测到 LAN IPv6'
end

local ipv6_opt = pxe_option("pxe_ipxe6", "iPXE IPv6 启动菜单",
	"【注意】IPv6 启动菜单参数必须以完整 URL表示；可直接输入完整 URL，也可只输入文件名系统会自动补其地址，或使用下方“选择菜单文件”。", "", ipv6_example)
ipv6_opt.placeholder = ipv6_example
ipv6_opt.size = 80
ipv6_opt.validate = function(self, value, section)
	local v = pxe_trim(value)
	if v == "" then return "" end
	if v:match("^%a[%w+.-]*://") then return v end
	if #ipv6_addrs == 0 then
		return nil, "未检测到 LAN IPv6，请填写完整 URL"
	end
	v = v:gsub("^/+", "")
	return "tftp://[" .. ipv6_addrs[1] .. "]/" .. v
end

local ipv6_hint_opt = s:taboption("tftp", DummyValue, "_pxe_ipv6_hint", "&nbsp;", "")
ipv6_hint_opt.value = ipv6_hint
ipv6_hint_opt.rawhtml = true

local picker_opt = s:taboption("tftp", DummyValue, "_pxe_ipv6_picker", "&nbsp;", "")
picker_opt.value = build_ipv6_picker(ipv6_addrs[1] or "", list_tftp_files())
picker_opt.rawhtml = true

tag_s = m:section(TypedSection, "tag", translate("Tag"))
tag_s.template = "cbi/tblsection"
tag_s.anonymous = false
tag_s.addremove = true
tag_s.sortable = true
tag_s.extedit = "dhcp_tag_config/%s"
function tag_s.create(e, t)
	TypedSection.create(e, t)
	luci.http.redirect(e.extedit:format(t))
end
function tag_s.remove(e, t)
	m.uci:foreach("dhcp", "host", function(s)
		local tags = s.tag or {}
		if #tags > 0 then
			for i = #tags, 1, -1 do
				if t == tags[i] then
					sys.call('uci -q del_list dhcp.' .. s[".name"] .. '.tag="' .. t .. '"')
				end
			end
		end
	end)
	TypedSection.remove(e, t)
end

o = tag_s:option(DynamicList, "dhcp_option", translate("DHCP-Options"))

o = tag_s:option(Flag, "force", translate("Force") .. " " .. translate("DHCP-Options"))
o.default = 0
o.rmempty  = false


s = m:section(TypedSection, "host", translate("Static Leases"),
	translate("Static leases are used to assign fixed IP addresses and symbolic hostnames to " ..
		"DHCP clients. They are also required for non-dynamic interface configurations where " ..
		"only hosts with a corresponding lease are served.") .. "<br />" ..
	translate("Use the <em>Add</em> Button to add a new lease entry. The <em>MAC-Address</em> " ..
		"identifies the host, the <em>IPv4-Address</em> specifies the fixed address to " ..
		"use, and the <em>Hostname</em> is assigned as a symbolic name to the requesting host. " ..
		"The optional <em>Lease time</em> can be used to set non-standard host-specific " ..
		"lease time, e.g. 12h, 3d or infinite."))

s.addremove = true
s.anonymous = true
s.template = "cbi/tblsection"
s.extedit = "dhcp_static_leases_config/%s"

name = s:option(Value, "name", translate("Hostname"))
name.datatype = "hostname"
name.rmempty  = true

mac = s:option(Value, "mac", translate("<abbr title=\"Media Access Control\">MAC</abbr>-Address"))
mac.datatype = "list(macaddr)"
mac.rmempty  = true

ip = s:option(Value, "ip", translate("<abbr title=\"Internet Protocol Version 4\">IPv4</abbr>-Address"))
ip.datatype = "or(ip4addr,'ignore')"

--time = s:option(Value, "leasetime", translate("Lease time"))
--time.rmempty = true

tag = s:option(DynamicList, 'tag', translate('Tag'))
m.uci:foreach("dhcp", "tag", function(s)
	tag:value(s[".name"])
end)

duid = s:option(Value, "duid", translate("DUID"))
duid.datatype = "and(rangelength(20,36),hexstring)"

hostid = s:option(Value, "hostid", translate("<abbr title=\"Internet Protocol Version 6\">IPv6</abbr>-Suffix (hex)"))

ipc.neighbors({ family = 4 }, function(n)
	if n.mac and n.dest then
		ip:value(n.dest:string())
		mac:value(n.mac, "%s (%s)" %{ n.mac, n.dest:string() })
	end
end)

function ip.validate(self, value, section)
	local m = mac:formvalue(section) or ""
	local n = name:formvalue(section) or ""
	if value and #n == 0 and #m == 0 then
		return nil, translate("One of hostname or mac address must be specified!")
	end
	return Value.validate(self, value, section)
end

m:section(SimpleSection).template = "admin_network/lease_status"

m.on_after_commit = function(self)
	self.uci:foreach("dhcp", "dnsmasq", function(s)
		if s.dhcp_boot then
			self.uci:delete("dhcp", s[".name"], "dhcp_boot")
		end
	end)
	self.uci:commit("dhcp")
	sys.call("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
	luci.http.header("Set-Cookie", "pxe_saved=1; Path=/; Max-Age=10")
	return true
end

return m
