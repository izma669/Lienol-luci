#!/bin/sh
# GMediaRender 下载器：下载歌曲 + 封面 + 歌词，一次性写入音频标签
# 用法: gmediarender-dl.sh <音频URL> <保存路径> <封面URL> <日志文件>

URL="$1"
OUT="$2"
COVER_URL="$3"
LOG="$4"
[ -z "$LOG" ] && LOG=/tmp/gmediarender_dl.log

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 供 LuCI 页面显示的状态
STATE=/tmp/gmr_dl_state
echo "idle|" > "$STATE" 2>/dev/null

# 同一输出文件只允许一个下载任务
LOCK="/tmp/gmr-dl-$(printf '%s' "$OUT" | md5sum | cut -c1-12).lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    log "已有相同文件的下载任务在进行，跳过本次"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null; echo "idle|" > "$STATE" 2>/dev/null' EXIT INT TERM

# 新任务开始：清掉上一次的结果，避免旧消息串到新歌
rm -f /tmp/gmr_dl_result

uci_get() { uci -q get "gmediarender.main.$1" 2>/dev/null; }

DL_ENABLE=$(uci_get auto_download); [ -z "$DL_ENABLE" ] && DL_ENABLE=0
SKIP_SAME=$(uci_get cover_skip_existing); [ -z "$SKIP_SAME" ] && SKIP_SAME=1
LYRIC_ENABLE=$(uci -q get gmediarender.main.lyric_enabled 2>/dev/null)
[ -z "$LYRIC_ENABLE" ] && LYRIC_ENABLE=0

TMP="$OUT.part"
COVER=""
LYRICS=""

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 600 -o "$2" "$1" >/dev/null 2>&1
    else
        wget -q -O "$2" "$1" >/dev/null 2>&1
    fi
}

embedded_size() {
    ffmpeg -v error -i "$1" -map 0:v:0 -c copy -f image2pipe - 2>/dev/null | wc -c | tr -d ' '
}

# 1) 下载封面
if [ -n "$COVER_URL" ]; then
    TMPS="/tmp/gmr-cover.$$"
    fetch "$COVER_URL" "$TMPS"
    if [ -s "$TMPS" ]; then
        CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$TMPS" 2>/dev/null | tr -d '\r')
        case "$CODEC" in
            mjpeg|png)
                COVER="$TMPS"
                ;;
            *)
                if ffmpeg -v error -y -i "$TMPS" -frames:v 1 -q:v 2 "$TMPS.jpg" >>"$LOG" 2>&1; then
                    COVER="$TMPS.jpg"
                fi
                rm -f "$TMPS"
                ;;
        esac
        if [ -n "$COVER" ]; then
            echo "cover_done|$OUT" > "$STATE"
            log "封面下载完成（$(wc -c < "$COVER" | tr -d ' ') 字节）"
        else
            log "封面格式无法识别，跳过封面"
        fi
    else
        log "封面下载失败，跳过封面"
    fi
fi

# 2) 已内置同尺寸封面则跳过
if [ -n "$COVER" ] && [ "$SKIP_SAME" = "1" ] && [ -f "$OUT" ]; then
    NEW_SIZE=$(wc -c < "$COVER" | tr -d ' ')
    OLD_SIZE=$(embedded_size "$OUT")
    if [ -n "$OLD_SIZE" ] && [ "$OLD_SIZE" -gt 0 ] 2>/dev/null && [ "$OLD_SIZE" = "$NEW_SIZE" ]; then
        log "同名文件已内置相同大小封面，已跳过：$(basename "$OUT")"
        echo "skip|$OUT|$(date +%s)" > /tmp/gmr_dl_result
        rm -f "$COVER"
        exit 0
    fi
fi

# 3) 下载音频
echo "downloading|$OUT" > "$STATE"
log "开始下载：$(basename "$OUT")"
if fetch "$URL" "$TMP" && [ -s "$TMP" ]; then
    mv -f "$TMP" "$OUT"
else
    rm -f "$TMP"
    log "下载失败：$URL"
    echo "fail|$OUT|$(date +%s)" > /tmp/gmr_dl_result
    [ -n "$COVER" ] && rm -f "$COVER"
    exit 1
fi
log "歌曲文件下载完成：$(basename "$OUT")"
echo "audio_done|$OUT" > "$STATE"

# 3.5) 校验确实是音频
FMT=$(ffprobe -v error -show_entries format=format_name -of csv=p=0 "$OUT" 2>/dev/null | tr -d '\r')
case "$FMT" in
    ""|*html*)
        rm -f "$OUT"
        log "下载内容不是有效的音频文件，已删除"
        echo "fail|$OUT|$(date +%s)" > /tmp/gmr_dl_result
        exit 1
        ;;
esac

EXT=$(basename "$OUT" | sed 's/.*\.//' | tr 'A-Z' 'a-z')
case "$EXT" in
    mp3|flac|m4a|mp4) FORMAT_OK=1 ;;
    *) FORMAT_OK=0 ;;
esac

# 4) 匹配歌词（只在支持写标签的格式上做）
if [ "$LYRIC_ENABLE" = "1" ] && [ "$FORMAT_OK" = "1" ]; then
    echo "lyric_match|$OUT" > "$STATE"
    log "正在匹配歌词：$(basename "$OUT")"
    LYRICS=$(/usr/libexec/gmediarender-lyric.lua --fetch "$OUT" 2>/dev/null)
    if [ -n "$LYRICS" ]; then
        log "歌词匹配成功（$(printf '%s' "$LYRICS" | wc -l | tr -d ' ') 行）"
    else
        log "未找到匹配歌词"
    fi
fi

NEW="$OUT.tmp.$$.$EXT"

# 5) 一次性写入封面 + 歌词
if [ "$FORMAT_OK" = "1" ] && { [ -n "$COVER" ] || [ -n "$LYRICS" ]; }; then
    echo "embedding|$OUT" > "$STATE"
    set -- -v error -y -i "$OUT"
    [ -n "$COVER" ] && set -- "$@" -i "$COVER"
    if [ -n "$COVER" ]; then
        set -- "$@" -map 0:a -map 1:v
    else
        set -- "$@" -map 0
    fi
    set -- "$@" -c copy
    if [ "$EXT" = "mp3" ]; then
        set -- "$@" -id3v2_version 3
        [ -n "$COVER" ] && set -- "$@" -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)"
    elif [ -n "$COVER" ]; then
        set -- "$@" -disposition:v attached_pic
    fi
    if [ -n "$LYRICS" ]; then
        if [ "$EXT" = "flac" ]; then
            set -- "$@" -metadata "LYRICS=$LYRICS"
        else
            set -- "$@" -metadata "lyrics=$LYRICS"
        fi
    fi
    case "$EXT" in
        mp3)  set -- "$@" -f mp3  "$NEW" ;;
        flac) set -- "$@" -f flac "$NEW" ;;
        m4a)  set -- "$@" -f ipod "$NEW" ;;
        mp4)  set -- "$@" -f mp4  "$NEW" ;;
    esac
    ffmpeg "$@" >>"$LOG" 2>&1
    if [ -s "$NEW" ]; then
        mv -f "$NEW" "$OUT"
        if [ -n "$LYRICS" ]; then
            log "封面与歌词已内嵌：$(basename "$OUT")"
            echo "done_lyric|$OUT|$(date +%s)" > /tmp/gmr_dl_result
        else
            log "封面已内嵌（未匹配到歌词）：$(basename "$OUT")"
            echo "done_cover|$OUT|$(date +%s)" > /tmp/gmr_dl_result
        fi
    else
        rm -f "$NEW"
        log "写入标签失败，文件保持原样"
        echo "fail|$OUT|$(date +%s)" > /tmp/gmr_dl_result
    fi
elif [ "$FORMAT_OK" = "0" ]; then
    log "格式 .$EXT 不支持写入封面/歌词，已跳过：$(basename "$OUT")"
    echo "nofmt|$OUT|$(date +%s)" > /tmp/gmr_dl_result
else
    log "已下载歌曲文件（无封面/歌词可写入）：$(basename "$OUT")"
    echo "done|$OUT|$(date +%s)" > /tmp/gmr_dl_result
fi

[ -n "$COVER" ] && rm -f "$COVER"
exit 0