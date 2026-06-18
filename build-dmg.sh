#!/usr/bin/env bash
# ============================================================================
# WonderHub Class - dmg 打包脚本（独立、可重复执行）
# ============================================================================
# 只依赖: 一个已签名的 .app
# 不会修改 .app 本身，可放心多次运行
#
# 用法:
#   ./scripts/build-dmg.sh [path/to/WonderHub Class.app] [output.dmg]
#
#   ./scripts/build-dmg.sh                      # 默认 ./WonderHub Class.app -> ./dist/WonderHub Class.dmg
#   ./scripts/build-dmg.sh ./MyApp.app          # 指定输入
#   ./scripts/build-dmg.sh ./MyApp.app /tmp/x.dmg  # 自定义输出
#
# 选项:
#   --bg <png>             自定义背景图（推荐 540x380）
#   --icon-size <int>      Finder 图标大小，默认 128
#   --win-size WxH         窗口尺寸，默认 540x380（背景图存在时自动取其尺寸）
# ============================================================================

set -euo pipefail

# ---------- 默认值 ----------
APP_PATH=""
OUTPUT_DMG=""
DMG_BG="${DMG_BG:-}"
ICON_SIZE=128
WIN_W=540
WIN_H=380

# ---------- 颜色 ----------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_RST='\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''
fi
info()  { echo -e "${C_BLU}>>${C_RST} $*"; }
ok()    { echo -e "${C_GRN}✓${C_RST}  $*"; }
warn()  { echo -e "${C_YEL}!${C_RST}  $*"; }
err()   { echo -e "${C_RED}✗${C_RST}  $*" >&2; }

usage() { sed -n '2,16p' "$0"; exit 1; }

# ---------- 参数解析 ----------
positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bg) DMG_BG="$2"; shift 2;;
        --icon-size) ICON_SIZE="$2"; shift 2;;
        --win-size)
            [[ "$2" =~ ^([0-9]+)x([0-9]+)$ ]] || { err "--win-size 格式: WxH"; exit 1; }
            WIN_W="${BASH_REMATCH[1]}" WIN_H="${BASH_REMATCH[2]}"
            shift 2;;
        -h|--help) usage;;
        -*) err "未知参数: $1"; usage;;
        *) positional+=("$1"); shift;;
    esac
done

APP_PATH="${positional[0]:-$(pwd)/WonderHub Class.app}"
OUTPUT_DMG="${positional[1]:-$(dirname "$APP_PATH")/dist/$(basename "$APP_PATH" .app).dmg}"
APP_NAME="$(basename "$APP_PATH" .app)"

# ---------- 环境检查 ----------
need() { command -v "$1" >/dev/null 2>&1 || { err "缺少依赖: $1"; exit 1; }; }
for c in hdiutil osascript sips ditto; do need "$c"; done

[[ -d "$APP_PATH" ]] || { err "找不到 App: $APP_PATH"; exit 1; }
mkdir -p "$(dirname "$OUTPUT_DMG")"

# ---------- 可选背景图 ----------
BG_FILE=""
if [[ -n "$DMG_BG" ]]; then
    [[ -f "$DMG_BG" ]] || { err "找不到背景图: $DMG_BG"; exit 1; }
    # 自动取背景图尺寸
    bw=$(sips -g pixelWidth  "$DMG_BG" 2>/dev/null | awk '/pixelWidth/{print $2}')
    bh=$(sips -g pixelHeight "$DMG_BG" 2>/dev/null | awk '/pixelHeight/{print $2}')
    if [[ -n "$bw" && -n "$bh" ]]; then
        WIN_W="$bw"; WIN_H="$bh"
        info "背景图尺寸: ${bw}x${bh}，窗口随之调整"
    fi
    BG_FILE="$DMG_BG"
fi

# ---------- 计算图标坐标 ----------
POS_APP_X=$((WIN_W / 4))
POS_APP_Y=$((WIN_H / 2))
POS_APPS_X=$((WIN_W * 3 / 4))
POS_APPS_Y=$((WIN_H / 2))

info "参数"
echo "   App     : $APP_PATH"
echo "   Output  : $OUTPUT_DMG"
echo "   Window  : ${WIN_W}x${WIN_H}"
echo "   IconSize: $ICON_SIZE"
echo "   BG      : ${BG_FILE:-<无>}"

# ---------- staging ----------
info "准备 staging..."
STAGE="$(mktemp -d -t dmgstage.XXXXXX)"
trap 'rm -rf "$STAGE" "$STAGE.rw.dmg"' EXIT

ditto "$APP_PATH" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

if [[ -n "$BG_FILE" ]]; then
    mkdir -p "$STAGE/.background"
    cp "$BG_FILE" "$STAGE/.background/background.png"
    BG_FOR_AS="$STAGE/.background/background.png"
else
    BG_FOR_AS=""
fi

# ---------- 制作读写 dmg ----------
info "创建读写 dmg..."
hdiutil create -ov -format UDRW \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    "$STAGE.rw.dmg" >/dev/null

# ---------- AppleScript 设置布局 ----------
info "设置 Finder 拖拽布局..."
AS="$(mktemp -t dmglayout.XXXXXX.applescript)"
cat >"$AS" <<EOF
on run argv
    set stagePath to item 1 of argv
    set winW      to (item 2 of argv) as integer
    set winH      to (item 3 of argv) as integer
    set posAppX   to (item 4 of argv) as integer
    set posAppY   to (item 5 of argv) as integer
    set posAppsX  to (item 6 of argv) as integer
    set posAppsY  to (item 7 of argv) as integer
    set bgArg     to item 8 of argv
    set iconSize  to (item 9 of argv) as integer

    tell application "Finder"
        tell disk (stagePath as POSIX file)
            open
            delay 1
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {0, 0, winW, winH}
            set theViewOptions to the icon view options of container window
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to iconSize
            if bgArg is not "" then
                set background picture of theViewOptions to file (bgArg as POSIX file)
            end if
            set position of item "$APP_NAME.app" of container window to {posAppX, posAppY}
            try
                set position of item "Applications" of container window to {posAppsX, posAppsY}
            end try
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
EOF

osascript "$AS" \
    "$STAGE" "$WIN_W" "$WIN_H" \
    "$POS_APP_X" "$POS_APP_Y" "$POS_APPS_X" "$POS_APPS_Y" \
    "$BG_FOR_AS" "$ICON_SIZE" \
    || warn "AppleScript 布局失败（不影响 dmg 生成），请到 系统设置→隐私与安全性→自动化 授权"

rm -f "$AS"

# ---------- 转压缩只读 dmg ----------
info "压缩为 UDZO..."
hdiutil convert "$STAGE.rw.dmg" -format UDZO -ov -o "$OUTPUT_DMG" >/dev/null

ok "完成"
echo "============================================="
echo " DMG: $OUTPUT_DMG"
echo "============================================="