-- Licensed to the public under the Apache License 2.0.

m = Map("ksmbd", translate("Network Shares (KSMBD)"))

s = m:section(TypedSection, "globals", translate("KSMBD is an opensource In-kernel SMB1/2/3 server"))
s.anonymous = true

s:tab("general",  translate("General Settings"))
s:tab("template", translate("Edit Template"))
s:tab("log", translate("日志记录"))

s:taboption("general", Value, "description", translate("Description"))

o = s:taboption("general", Value, "workgroup", translate("Workgroup"))
o.placeholder = 'WORKGROUP'

tmpl = s:taboption("template", Value, "_tmpl",
	translate("Edit the template that is used for generating the ksmbd configuration."), 
	translate("This is the content of the file '/etc/ksmbd/smb.conf.template' from which your ksmbd configuration will be generated. \
			Values enclosed by pipe symbols ('|') should not be changed. They get their values from the 'General Settings' tab."))

tmpl.template = "cbi/tvalue"
tmpl.rows = 20

function tmpl.cfgvalue(self, section)
	return nixio.fs.readfile("/etc/ksmbd/smb.conf.template")
end

function tmpl.write(self, section, value)
	value = value:gsub("\r\n?", "\n")
	nixio.fs.writefile("/etc/ksmbd/smb.conf.template", value)
end

lp = s:taboption("log", Value, "log_path", translate("日志文件路径"))
lp.placeholder = "/mnt/mmcblk0p1/log/ksmbd.log"
lp.default = "/mnt/mmcblk0p1/log/ksmbd.log"
lp.rmempty = false
lp.description = translate("日志会写到这个文件（建议放 SD 卡 / U 盘，重启不丢）。保存后会自动重启日志抓取。")

function lp.write(self, section, value)
	local function shq(x) return "'" .. tostring(x or ""):gsub("'", "'\\''") .. "'" end
	m.uci:set("ksmbd", section, "log_path", value)
	local sys = require "luci.sys"
	if m.uci:get("ksmbd", section, "log_enabled") == "1" then
		local dir = value:match("^(.*)/[^/]*$") or "/tmp"
		sys.call("start-stop-daemon -K -q -p /var/run/ksmbd-log.pid -s TERM 2>/dev/null; rm -f /var/run/ksmbd-log.pid")
		sys.call("mkdir -p " .. shq(dir))
		sys.call("start-stop-daemon -S -q -b -x /sbin/logread -- -f -e ksmbd -F " .. shq(value) .. " -p /var/run/ksmbd-log.pid")
	end
end

logbox = s:taboption("log", DummyValue, "_logbox", translate("日志内容"))
logbox.rawhtml = true
logbox.default = [[
<div style="margin-bottom:10px;">
	<label style="margin-right:14px;"><input type="checkbox" id="ksmbd_log_en" /> 启用日志抓取</label>
	<button class="cbi-button cbi-button-apply" id="ksmbd_log_refresh">刷新</button>
	<button class="cbi-button" id="ksmbd_log_clear" style="margin-left:6px;">清空</button>
	<span id="ksmbd_log_state" style="margin-left:12px;color:#888;font-size:13px;"></span>
</div>
<div style="font-size:12px;color:#888;margin-bottom:6px;">
	只抓取 ksmbd 自己的内核消息（含 __ipc_heartbeat），最多显示最近 300 行；文件超过 1MB 会自动只保留最近 256KB。
</div>
<pre id="ksmbd_log_body" style="height:50vh;overflow:auto;background:#111;color:#7CFC7C;font-size:12px;line-height:1.5;padding:10px;border-radius:4px;white-space:pre-wrap;word-break:break-all;margin:0;">（暂无日志）</pre>
<script type="text/javascript">
(function(){
	var base = '/cgi-bin/luci/admin/nas/ksmbd';
	function paint(r){
		var cb = document.getElementById('ksmbd_log_en');
		var st = document.getElementById('ksmbd_log_state');
		var body = document.getElementById('ksmbd_log_body');
		if (cb) cb.checked = !!r.enabled;
		if (st) st.textContent = (r.running ? '● 正在抓取' : '● 未抓取') + ' | ' + ((r.lines && r.lines.length) || 0) + ' 行 | ' + (r.path || '');
		if (body) body.textContent = (r.lines && r.lines.length) ? r.lines.join('\n') : '（暂无日志）';
	}
	function load(){
		var x = new XMLHttpRequest();
		x.open('GET', base + '/logdata?_=' + Date.now(), true);
		x.onreadystatechange = function(){
			if (x.readyState === 4 && x.status === 200) {
				try { paint(JSON.parse(x.responseText)); } catch(e) {}
			}
		};
		x.send();
	}
	function toggle(on){
		var x = new XMLHttpRequest();
		var p = document.getElementById('cbid.ksmbd.@globals[0].log_path');
		x.open('POST', base + '/logtoggle', true);
		x.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
		x.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
		x.onreadystatechange = function(){ if (x.readyState === 4) load(); };
		x.send('enabled=' + (on ? '1' : '0') + '&path=' + encodeURIComponent(p ? p.value : ''));
	}
	function clearLog(){
		var x = new XMLHttpRequest();
		x.open('POST', base + '/logclear', true);
		x.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
		x.onreadystatechange = function(){ if (x.readyState === 4) load(); };
		x.send('');
	}
	var cb = document.getElementById('ksmbd_log_en');
	if (cb) cb.onchange = function(){ toggle(this.checked); };
	var rb = document.getElementById('ksmbd_log_refresh');
	if (rb) rb.onclick = load;
	var cbb = document.getElementById('ksmbd_log_clear');
	if (cbb) cbb.onclick = clearLog;
	load();
	setInterval(load, 5000);
})();
</script>
]]

s = m:section(TypedSection, "share", translate("Shared Directories")
  , translate("Please add directories to share. Each directory refers to a folder on a mounted device."))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"

s:option(Value, "name", translate("Name"))
pth = s:option(Value, "path", translate("Path"))
if nixio.fs.access("/etc/config/fstab") then
        pth.titleref = luci.dispatcher.build_url("admin", "system", "fstab")
end

br = s:option(Flag, "browseable", translate("Browseable"))
br.rmempty = false
br.default = "yes"
br.enabled = "yes"
br.disabled = "no"

ro = s:option(Flag, "read_only", translate("Read-only"))
ro.rmempty = false
ro.enabled = "yes"
ro.disabled = "no"

fr = s:option(Flag, "force_root", translate("Force Root"))
fr.rmempty = false
fr.default = "1"
fr.enabled = "1"
fr.disabled = "0"

go = s:option(Flag, "guest_ok", translate("Allow guests"))
go.rmempty = false
go.enabled = "yes"
go.disabled = "no"
go.default = "yes"

io = s:option(Flag, "inherit_owner", translate("Inherit owner"))

hd = s:option(Flag, "hide_dot_files", translate("Hide dot files"))

cm = s:option(Value, "create_mask", translate("Create mask"),
        translate("Mask for new files"))
cm.rmempty = true
cm.size = 4
cm.default = "0666"

dm = s:option(Value, "dir_mask", translate("Directory mask"),
        translate("Mask for new directories"))
dm.rmempty = true
dm.size = 4
dm.default = "0777"

return m
