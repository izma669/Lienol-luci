local m, s, o

m = Map("gmediarender", "GR_DLNA音频接收器",
    "GMediaRender 是一个 UPnP/DLNA 音频渲染器，可以将手机或电脑上的音频推送到此设备播放。")

-- 服务状态 / 正在播放等展示模块已经移到 888 端口的“音乐中心”，
-- 这里只保留设置项，避免 LuCI 管理面板里重复展示。

-- ==========================================
-- 服务状态（含自动刷新）
-- ==========================================
local st = m:section(SimpleSection)
st.template = "gmediarender/status"

-- ==========================================
-- 基本设置模块
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", "基本设置")
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", "启用服务")
o.default = "0"
o.rmempty = false

o = s:option(Value, "friendly_name", "设备名称",
    "在 DLNA 客户端中显示的名称")
o.default = "OpenWrt-Speaker"
o.rmempty = false

o = s:option(Value, "interface", "监听接口",
    "绑定的 IP 地址或网卡名（如 br-lan 或 192.168.1.1）")
o.default = "br-lan"
o.rmempty = false

o = s:option(Value, "port", "端口",
    "UPnP 事件端口（默认 49152）")
o.datatype = "port"
o.default = "49152"
o.rmempty = false

o = s:option(Flag, "auto_download", "播放时自动下载",
    "当检测到开始播放新歌曲时，自动将其下载到指定目录，同时下载封面并内嵌到音乐文件。支持 MP3、FLAC、M4A（WAV、OGG、APE 等格式无法写入封面，会自动跳过封面嵌入，歌曲照常下载）")
o.default = "0"
o.rmempty = false

o = s:option(Value, "download_dir", "下载歌曲存放位置",
    "下载歌曲的默认保存路径，请确保目录已挂载且有足够空间")
o.default = "/mnt/mmcblk0p1/music"
o.rmempty = false

-- 下载封面并写入音频标签
-- （已并入“播放时自动下载”开关，不再单独提供选项）

-- 已有同尺寸封面时跳过（避免重复下载/重复写入）
o = s:option(Flag, "cover_skip_existing", "检测已内置封面（大小相同则跳过）",
    "下载前检查下载目录中同名文件：如果里面已内置封面、且大小与本次要下载的封面相同，就跳过下载和嵌入")
o.default = "1"
o.rmempty = false
o:depends("auto_download", "1")

-- 给 download_dir 注入“浏览”按钮（弹窗逻辑放在独立模板里）
o = s:option(DummyValue, "_dirpicker", "")
o.template = "gmediarender/dirpicker"

-- ==========================================
-- 服务控制模块
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", "服务控制")
s.anonymous = true
s.addremove = false

o = s:option(Button, "_reload", "重载服务")
o.inputtitle = "立即重载"
o.inputstyle = "apply"
o.write = function()
    luci.sys.call("/etc/init.d/gmediarender restart >/dev/null 2>&1")
end

return m
