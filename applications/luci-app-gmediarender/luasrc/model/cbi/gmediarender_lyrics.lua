-- GMediaRender 歌词下载设置（配置写在 gmediarender.main 里，不额外建配置文件）
local m, s, o

m = Map("gmediarender", translate("歌词下载"),
        translate("下载歌曲时按歌名与时长匹配歌词，可直接写入歌曲标签。"))

s = m:section(NamedSection, "main", "gmediarender", translate("歌词设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "lyric_enabled", translate("启用歌词下载"))
o.default = "1"
o.rmempty = false
o.description = translate("关闭后下载歌曲时不再匹配歌词。")

o = s:option(ListValue, "lyric_mode", translate("写入方式"))
o:value("embed", translate("嵌入到歌曲文件（推荐）"))
o:value("lrc", translate("只保存同名 .lrc"))
o:value("both", translate("两者都要"))
o.default = "embed"
o.rmempty = false

o = s:option(MultiValue, "lyric_servers", translate("启用的服务器"),
             translate("勾选要使用的预设服务器。"))
o.default = { "lrclib", "kuwo", "netease" }
o.rmempty = false
o.widget = "checkbox"
o:value("lrclib", "LRCLIB（公开免费，含时间轴）")
o:value("kuwo", "酷我（国内，含时间轴）")
o:value("netease", "网易云（国内，含时间轴）")

o = s:option(Value, "lyric_order", translate("尝试顺序"),
             translate("逗号分隔，例如 lrclib,kuwo,netease；留空按勾选顺序。"))
o.default = "lrclib,kuwo,netease"
o.rmempty = true

o = s:option(Value, "lyric_tolerance", translate("时长容差"), translate("秒"))
o.datatype = "uinteger"
o.default = "8"
o.rmempty = true
o.description = translate("多个候选时选时长最接近的；差值过大（超 4 倍容差或 30 秒）则放弃。")

o = s:option(DynamicList, "lyric_custom", translate("自定义服务器"),
             translate("每行一个 URL 模板，作为补充源。"))
o.placeholder = "https://example.com/lyric?title={title}&artist={artist}"
o.description = translate("占位符：{title} {artist}（自动 URL 编码）、{title_raw} {artist_raw}（不编码）。")

s = m:section(SimpleSection, translate("立即执行"))
s.anonymous = true

o = s:option(Button, "_scan", translate("扫描现有歌曲"))
o.inputtitle = translate("扫描现有歌曲")
o.inputstyle = "apply"
function o.write()
    luci.sys.call("(/usr/libexec/gmediarender-lyric.lua --scan >/dev/null 2>&1 &)")
    luci.http.redirect(luci.dispatcher.build_url("admin/services/gmediarender/lyrics"))
end

s = m:section(SimpleSection)
s.anonymous = true
o = s:option(DummyValue, "_hint")
o.rawhtml = true
o.value = translate("日志：/tmp/gmediarender-lyric.log　|　文件名按「歌名-歌手」解析。")

return m