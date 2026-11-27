-- GMediaRender 封面下载
local m, s, o

m = Map("gmediarender")
m.title = nil
m.description = nil

s = m:section(NamedSection, "main", "gmediarender", translate("封面内嵌"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "cover_skip_existing", translate("检测已存在的封面"))
o.default = "1"
o.rmempty = false
o.description = translate("同名文件已内置同尺寸封面时，跳过下载与嵌入。")

s = m:section(SimpleSection, translate("说明"))
s.anonymous = true
o = s:option(DummyValue, "_hint")
o.rawhtml = true
o.value = translate(
    "封面嵌入检测封装需要 ffmpeg、ffprobe，支持 MP3 / FLAC / M4A；" ..
    "WAV / OGG / APE 无法写入封面时会跳过封面，歌曲照常下载。")

return m