#!/bin/sh
# GMediaRender 下载器：下载歌曲 + 可选下载封面并嵌入音频标签
# 用法: gmediarender-dl.sh <音频URL> <保存路径> <封面URL> <日志文件>
# 依赖: curl/wget、ffmpeg、ffprobe、uci

URL="$1"
OUT="$2"
COVER_URL="$3"
LOG="$4"
[ -z "$LOG" ] && LOG=/tmp/gmediarender_dl.log

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 供 LuCI 页面显示的“正在下载/正在嵌入”状态
STATE=/tmp/gmr_dl_state
echo "idle|" > "$STATE" 2>/dev/null

# 同一个输出文件只允许一个下载任务（防止页面轮询/多标签重复下载互相覆盖）
LOCK="/tmp/gmr-dl-$(printf '%s' "$OUT" | md5sum | cut -c1-12).lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    log "已有相同文件的下载任务在进行，跳过本次"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null; echo "idle|" > "$STATE" 2>/dev/null' EXIT INT TERM

uci_get() { uci -q get "gmediarender.main.$1" 2>/dev/null; }

# “播放时自动下载”开关同时控制封面下载与内嵌
COVER_ENABLE=$(uci_get auto_download)
[ -z "$COVER_ENABLE" ] && COVER_ENABLE=0
SKIP_SAME=$(uci_get cover_skip_existing)
[ -z "$SKIP_SAME" ] && SKIP_SAME=1

TMP="$OUT.part"
COVER=""

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 600 -o "$2" "$1" >/dev/null 2>&1
    else
        wget -q -O "$2" "$1" >/dev/null 2>&1
    fi
}

# 取音频里已嵌入封面的字节数（没有则为 0）
embedded_size() {
    ffmpeg -v error -i "$1" -map 0:v:0 -c copy -f image2pipe - 2>/dev/null | wc -c | tr -d ' '
}

# 1) 先取封面（用于“是否已有同尺寸封面”的判断，以及后续嵌入）
if [ "$COVER_ENABLE" = "1" ] && [ -n "$COVER_URL" ]; then
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
        [ -z "$COVER" ] && log "封面格式无法识别，继续下载歌曲（不嵌入封面）"
    else
        log "封面下载失败，继续下载歌曲（不嵌入封面）"
    fi
fi

# 2) 检测开关：同名文件已内置与本次封面同样大小的封面 → 直接跳过
if [ -n "$COVER" ] && [ "$SKIP_SAME" = "1" ] && [ -f "$OUT" ]; then
    NEW_SIZE=$(wc -c < "$COVER" | tr -d ' ')
    OLD_SIZE=$(embedded_size "$OUT")
    if [ -n "$OLD_SIZE" ] && [ "$OLD_SIZE" -gt 0 ] 2>/dev/null && [ "$OLD_SIZE" = "$NEW_SIZE" ]; then
        log "同名文件已内置相同大小封面（${OLD_SIZE} 字节），跳过下载与嵌入：$(basename "$OUT")"
        echo "skip|$OUT|$(date +%s)" > /tmp/gmr_dl_result
        rm -f "$COVER"
        exit 0
    fi
fi

# 3) 下载音频（先写 .part，成功后再改名，避免半截文件覆盖旧文件）
echo "downloading|$OUT" > "$STATE" 2>/dev/null
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
log "下载完成：$(basename "$OUT")"

# 3.5) 校验下载内容确实是音频（防止把 404/错误页当成歌曲保存）
FMT=$(ffprobe -v error -show_entries format=format_name -of csv=p=0 "$OUT" 2>/dev/null | tr -d '\r')
case "$FMT" in
    ""|*html*)
        rm -f "$OUT"
        log "下载内容不是有效的音频文件，已删除"
        echo "fail|$OUT|$(date +%s)" > /tmp/gmr_dl_result
        exit 1
        ;;
esac

# 4) 嵌入封面
if [ -n "$COVER" ]; then
    echo "embedding|$OUT" > "$STATE" 2>/dev/null
    EXT=$(basename "$OUT" | sed 's/.*\.//' | tr 'A-Z' 'a-z')
    NEW="$OUT.tmp.$$.$EXT"
    case "$EXT" in
        mp3)
            ffmpeg -v error -y -i "$OUT" -i "$COVER" -map 0:a -map 1:v -c copy \
                -id3v2_version 3 -metadata:s:v title="Album cover" \
                -metadata:s:v comment="Cover (front)" -f mp3 "$NEW" >>"$LOG" 2>&1
            ;;
        flac)
            ffmpeg -v error -y -i "$OUT" -i "$COVER" -map 0:a -map 1:v -c copy \
                -disposition:v attached_pic -f flac "$NEW" >>"$LOG" 2>&1
            ;;
        m4a)
            ffmpeg -v error -y -i "$OUT" -i "$COVER" -map 0:a -map 1:v -c copy \
                -disposition:v attached_pic -f ipod "$NEW" >>"$LOG" 2>&1
            ;;
        mp4)
            ffmpeg -v error -y -i "$OUT" -i "$COVER" -map 0:a -map 1:v -c copy \
                -disposition:v attached_pic -f mp4 "$NEW" >>"$LOG" 2>&1
            ;;
        *)
            log "格式 .$EXT 不支持写入封面，已跳过"
            echo "nofmt|$OUT|$(date +%s)" > /tmp/gmr_dl_result
            rm -f "$COVER"
            exit 0
            ;;
    esac
    if [ -s "$NEW" ]; then
        mv -f "$NEW" "$OUT"
        log "已嵌入封面（$(wc -c < "$COVER" | tr -d ' ') 字节）"
        echo "done|$OUT|$(date +%s)" > /tmp/gmr_dl_result
    else
        rm -f "$NEW"
        log "封面嵌入失败，文件保持原样"
        echo "fail|$OUT|$(date +%s)" > /tmp/gmr_dl_result
    fi
    rm -f "$COVER"
fi

exit 0
