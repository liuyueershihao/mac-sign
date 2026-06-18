#!/usr/bin/env bash
# ============================================================================
# WonderHub Class - 签名 + 公证脚本（独立）
# ============================================================================
# 用法:
#   ./scripts/sign.sh [path/to/WonderHub Class.app] \
#       --p12   /path/to/DeveloperID.p12 \
#       --p12-pass 'p12密码' \
#       --authkey /path/to/AuthKey_XXXXXXXXXX.p8 \
#       --key-id XXXXXXXXXX \
#       --issuer  11111111-2222-3333-4444-555555555555
#
# 也支持环境变量:
#     P12_PATH / P12_PASS
#     AC_API_KEY_PATH / AC_API_KEY_ID / AC_API_ISSUER_ID
#     APP_SIGN_IDENTITY（留空自动从钥匙串选）
#
# 选项:
#     --app <path>           .app 路径（也支持位置参数）
#     --skip-notarize        只签名不公证
#     --notarize-only        只对当前已签名的 .app 做公证（不再签一次）
#     --dry-run
# ============================================================================

set -euo pipefail

# ---------- 默认值 ----------
APP_PATH=""
P12_PATH="${P12_PATH:-}"
P12_PASS="${P12_PASS:-}"
AC_API_KEY_PATH="${AC_API_KEY_PATH:-}"
AC_API_KEY_ID="${AC_API_KEY_ID:-}"
AC_API_ISSUER_ID="${AC_API_ISSUER_ID:-}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
SKIP_NOTARIZE=0
NOTARIZE_ONLY=0
DRY_RUN=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.mac.plist"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
[[ -f "$KEYCHAIN_PATH" ]] || KEYCHAIN_PATH="$(security default-keychain 2>/dev/null | xargs)"

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

# ---------- 参数解析 ----------
usage() { sed -n '2,28p' "$0"; exit 1; }
positional=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="$2"; shift 2;;
        --p12) P12_PATH="$2"; shift 2;;
        --p12-pass) P12_PASS="$2"; shift 2;;
        --authkey) AC_API_KEY_PATH="$2"; shift 2;;
        --key-id) AC_API_KEY_ID="$2"; shift 2;;
        --issuer) AC_API_ISSUER_ID="$2"; shift 2;;
        --identity) APP_SIGN_IDENTITY="$2"; shift 2;;
        --skip-notarize) SKIP_NOTARIZE=1; shift;;
        --notarize-only) NOTARIZE_ONLY=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage;;
        -*) err "未知参数: $1"; usage;;
        *) positional="$positional $1"; shift;;
    esac
done
[[ -n "$positional" ]] && APP_PATH="${positional# }"
[[ -z "$APP_PATH" ]] && APP_PATH="$(pwd)/WonderHub Class.app"

APP_NAME="$(basename "$APP_PATH" .app)"

# ---------- 环境检查 ----------
need() { command -v "$1" >/dev/null 2>&1 || { err "缺少依赖: $1"; exit 1; }; }
for c in codesign xcrun security ditto; do need "$c"; done

[[ -d "$APP_PATH" ]]     || { err "找不到 App: $APP_PATH"; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { err "找不到 entitlements: $ENTITLEMENTS"; exit 1; }

# PkgInfo 自动修复
PKGINFO="$APP_PATH/Contents/PkgInfo"
if [[ -f "$PKGINFO" ]]; then
    [[ "$(wc -c <"$PKGINFO")" -ne 8 ]] && { warn "PkgInfo 长度异常，修复为 APPL????"; printf 'APPL????' >"$PKGINFO"; }
else
    warn "PkgInfo 缺失，补全"; mkdir -p "$(dirname "$PKGINFO")"; printf 'APPL????' >"$PKGINFO"
fi

# ---------- 0. 导入 .p12 ----------
if [[ -n "$P12_PATH" ]]; then
    [[ -f "$P12_PATH" ]] || { err "找不到 .p12: $P12_PATH"; exit 1; }
    info "导入 .p12: $P12_PATH"
    security import "$P12_PATH" \
        -k "$KEYCHAIN_PATH" \
        -P "${P12_PASS:-}" \
        -A -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple: -s -k "${P12_PASS:-}" "$KEYCHAIN_PATH" 2>/dev/null || true
    ok ".p12 已导入"
fi

# ---------- 1. 自动检测签名身份 ----------
if [[ -z "$APP_SIGN_IDENTITY" ]]; then
    info "未指定签名身份，自动从钥匙串检测..."
    mapfile -t IDENTITIES < <(security find-identity -p codesigning -v "$KEYCHAIN_PATH" 2>/dev/null \
        | grep "Developer ID Application:" | awk -F'"' '{print $2}')
    if [[ ${#IDENTITIES[@]} -eq 0 ]]; then
        err "钥匙串里没找到 Developer ID Application，请用 --p12 重新导入"
        exit 1
    fi
    if [[ ${#IDENTITIES[@]} -eq 1 ]]; then
        APP_SIGN_IDENTITY="${IDENTITIES[0]}"
        ok "检测到: $APP_SIGN_IDENTITY"
    else
        echo "找到多个身份:"
        for i in "${!IDENTITIES[@]}"; do echo "  [$((i+1))] ${IDENTITIES[$i]}"; done
        read -rp "选择 [1-${#IDENTITIES[@]}]: " pick
        APP_SIGN_IDENTITY="${IDENTITIES[$((pick-1))]}"
    fi
fi

# ---------- 2. 解锁钥匙串 ----------
info "解锁钥匙串..."
security unlock-keychain -p "" "$KEYCHAIN_PATH" 2>/dev/null || \
    security unlock-keychain "$KEYCHAIN_PATH" 2>/dev/null || \
    warn "钥匙串可能仍处于锁定状态，签名失败请手动解锁"

# ---------- 3. 签名 ----------
sign_one() {
    local target="$1"
    codesign --force --deep --options=runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$APP_SIGN_IDENTITY" \
        --keychain "$KEYCHAIN_PATH" \
        "$target"
}

if [[ $DRY_RUN -eq 1 ]]; then
    cat <<EOF
================ DRY RUN ================
 App            : $APP_PATH
 Sign Identity  : $APP_SIGN_IDENTITY
 Keychain       : $KEYCHAIN_PATH
 Entitlements   : $ENTITLEMENTS
 P12            : ${P12_PATH:-<未提供>}
 Notarize       : $([[ $SKIP_NOTARIZE -eq 1 ]] && echo SKIP || echo YES)
   AuthKey      : ${AC_API_KEY_PATH:-<无>}
   Key ID       : ${AC_API_KEY_ID:-<无>}
   Issuer ID    : ${AC_API_ISSUER_ID:-<无>}
==========================================
EOF
    exit 0
fi

if [[ $NOTARIZE_ONLY -eq 0 ]]; then
    info "签名嵌套组件..."
    FW="$APP_PATH/Contents/Frameworks"
    [[ -d "$FW" ]] && find "$FW" \
        \( -name "*.framework" -o -name "*.app" -o -name "*.dylib" -o -name "*.so" \) \
        -maxdepth 3 | sort | while read -r f; do
            echo "   signing: $f"
            sign_one "$f"
        done

    MAIN="$APP_PATH/Contents/MacOS/$APP_NAME"
    [[ -x "$MAIN" ]] && { echo "   signing: $MAIN"; sign_one "$MAIN"; }

    info "签名主 App: $APP_PATH"
    sign_one "$APP_PATH"

    info "校验签名..."
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    ok "签名校验通过"
fi

# ---------- 4. 公证 ----------
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    # 尝试从文件名推断 Key ID
    if [[ -n "$AC_API_KEY_PATH" && -z "$AC_API_KEY_ID" ]]; then
        base="$(basename "$AC_API_KEY_PATH")"
        if [[ "$base" =~ AuthKey_([A-Z0-9]+)\.p8 ]]; then
            AC_API_KEY_ID="${BASH_REMATCH[1]}"
            ok "从文件名推断 Key ID: $AC_API_KEY_ID"
        fi
    fi

    [[ -n "$AC_API_KEY_PATH" && -f "$AC_API_KEY_PATH" ]] || { err "缺 .p8 AuthKey（--authkey）"; exit 1; }
    [[ -n "$AC_API_KEY_ID" ]]    || { err "缺 Key ID（--key-id）"; exit 1; }
    [[ -n "$AC_API_ISSUER_ID" ]] || { err "缺 Issuer ID（--issuer）"; exit 1; }

    OUT_DIR="$(dirname "$APP_PATH")/dist"
    mkdir -p "$OUT_DIR"
    ZIP_PATH="$OUT_DIR/$APP_NAME.zip"
    info "打包 zip 用于公证..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

    info "提交公证（1-5 分钟）..."
    NOTARY_JSON="$OUT_DIR/$APP_NAME.notary.json"
    xcrun notarytool submit "$ZIP_PATH" \
        --key "$AC_API_KEY_PATH" \
        --key-id "$AC_API_KEY_ID" \
        --issuer "$AC_API_ISSUER_ID" \
        --wait \
        --output-format json \
        >"$NOTARY_JSON"
    cat "$NOTARY_JSON"

    status=$(python3 -c "import json;print(json.load(open('$NOTARY_JSON')).get('status','Unknown'))" 2>/dev/null || echo "Unknown")
    SUBMISSION_ID=$(python3 -c "import json;print(json.load(open('$NOTARY_JSON')).get('id',''))" 2>/dev/null || echo "")

    if [[ "$status" != "Accepted" ]]; then
        err "公证失败: $status"
        [[ -n "$SUBMISSION_ID" ]] && \
            xcrun notarytool log "$SUBMISSION_ID" \
                --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" \
                "$OUT_DIR/$APP_NAME.notarylog.json"
        exit 1
    fi
    ok "公证 Accepted ✅"

    info "Stapling..."
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    ok "Staple 完成"
fi

echo "============================================="
ok "签名完成: $APP_PATH"
echo "============================================="