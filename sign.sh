#!/usr/bin/env bash
# ============================================================================
# WonderHub Class - 签名 + 公证脚本（独立） - 优化版
# ============================================================================
# 强制 bash 执行（zsh 跑会 auto re-exec）
if [[ -z "$BASH_VERSION" ]]; then
    exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

# ---------- 默认值 ----------
APP_PATH=""
P12_PATH="${P12_PATH:-}"
P12_PASS="${P12_PASS:-}"
AC_API_KEY_PATH="${AC_API_KEY_PATH:-}"
AC_API_KEY_ID="${AC_API_KEY_ID:-}"
AC_API_ISSUER_ID="${AC_API_ISSUER_ID:-}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
# 时间戳服务器 URL：留空走 codesign 默认（http://timestamp.apple.com/ts01），
# 机器连不上 Apple TSA 时用 --timestamp-url 指定其他 TSA
TIMESTAMP_URL="${TIMESTAMP_URL:-}"
SKIP_NOTARIZE=0
NOTARIZE_ONLY=0
DRY_RUN=0
TEST_MODE=0

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
        --timestamp-url) TIMESTAMP_URL="$2"; shift 2;;
        --skip-notarize) SKIP_NOTARIZE=1; shift;;
        --notarize-only) NOTARIZE_ONLY=1; shift;;
        --test-mode) TEST_MODE=1; SKIP_NOTARIZE=1; shift;;
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

[[ -d "$APP_PATH" ]]     || {
    err "找不到 App: $APP_PATH"
    exit 1
}
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
    security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "${P12_PASS:-}" -A -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple: -s -k "${P12_PASS:-}" "$KEYCHAIN_PATH" 2>/dev/null || true
    ok ".p12 已导入"
fi

# ---------- 1. 自动检测签名身份 ----------
if [[ -z "$APP_SIGN_IDENTITY" ]]; then
    info "未指定签名身份，自动从钥匙串检测..."
    IDENTITIES=()
    if [[ $TEST_MODE -eq 1 ]]; then
        while IFS= read -r line; do IDENTITIES+=("$line"); done < <(
            security find-identity -p codesigning -v "$KEYCHAIN_PATH" 2>/dev/null | awk -F'"' '/Identity/{print $2}'
        )
        if [[ ${#IDENTITIES[@]} -eq 0 ]]; then
            warn "测试模式：未找到任何 codesign 身份，将使用 ad-hoc 签名 (-)"
            APP_SIGN_IDENTITY="-"
        elif [[ ${#IDENTITIES[@]} -eq 1 ]]; then
            APP_SIGN_IDENTITY="${IDENTITIES[0]}"
        else
            APP_SIGN_IDENTITY="${IDENTITIES[0]}" # 默认取第一个，避免交互阻塞 CI
            warn "找到多个身份，自动选择首个: $APP_SIGN_IDENTITY"
        fi
    else
        while IFS= read -r line; do IDENTITIES+=("$line"); done < <(
            security find-identity -p codesigning -v "$KEYCHAIN_PATH" 2>/dev/null | grep "Developer ID Application:" | awk -F'"' '{print $2}'
        )
        if [[ ${#IDENTITIES[@]} -eq 0 ]]; then
            err "钥匙串里没找到 Developer ID Application，请用 --p12 重新导入"
            exit 1
        fi
        APP_SIGN_IDENTITY="${IDENTITIES[0]}"
        ok "检测到: $APP_SIGN_IDENTITY"
    fi
fi

# ---------- 2. 解锁钥匙串 + 永久授权 ----------
ensure_keychain_acl() {
    local kc="$1"
    [[ -f "$kc" ]] || return 0
    local probe; probe="$(mktemp -t kcprobe.XXXXXX)"
    : >"$probe"
    local out; out="$(codesign --force --sign - "$probe" 2>&1)"
    rm -f "$probe"
    if echo "$out" | grep -q "user interaction is not allowed"; then return 1; fi
    return 0
}

info "检查钥匙串 ACL 授权状态..."
for kc in "$HOME/Library/Keychains/login.keychain-db" "$HOME/Library/Keychains/build.keychain-db"; do
    [[ -f "$kc" ]] || continue
    security unlock-keychain -p "" "$kc" 2>/dev/null || security unlock-keychain "$kc" 2>/dev/null || true
    if ! ensure_keychain_acl "$kc"; then
        warn "钥匙串 $kc 未授权免密签名，CI 环境下可能卡死弹窗"
    fi
done

# ---------- 3. 签名 ----------

# 构建时间戳相关 flag。留空走 codesign 默认 TSA（Apple 的 timestamp.apple.com），
# 机器连不上时通过 --timestamp-url 指定其他 TSA。
TS_FLAGS=(--timestamp)
[[ -n "$TIMESTAMP_URL" ]] && TS_FLAGS+=(--timestamp-url "$TIMESTAMP_URL")

# 包装 codesign：
#   - 失败且原因是 "timestamp service is not available" → 立刻给出明确错误并退出
#     （不在每个调用点重复写 TSA 错误处理）
#   - 失败但不是时间戳错误 → 把 stderr 透传给调用方，让它走原来的 --no-strict fallback
#   - 成功 → 静默 return 0
do_codesign() {
    local target="$1"; shift
    local err_log
    err_log=$(mktemp -t cserr.XXXXXX)
    if codesign --force --options=runtime "${TS_FLAGS[@]}" \
        --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
        "$@" "$target" 2>"$err_log"; then
        rm -f "$err_log"
        return 0
    fi
    if grep -q "timestamp service is not available" "$err_log" 2>/dev/null; then
        cat "$err_log" >&2
        rm -f "$err_log"
        err ""
        err "❌ 时间戳服务 (TSA) 不可达，签名中断"
        err "   codesign --timestamp 默认连 http://timestamp.apple.com/ts01，"
        err "   当前机器连不上该地址（GFW / 内网 / 临时故障都可能）。"
        err ""
        err "   解决（任选其一）："
        err "     1. 测连通性:  curl -v http://timestamp.apple.com/ts01"
        err "     2. 用 --timestamp-url 指定其他 TSA，例如："
        err "          --timestamp-url http://timestamp.digicert.com"
        err "          --timestamp-url http://tsa.swisssign.net"
        err "          --timestamp-url http://timestamp.entrust.net/TSS/RFC3161sha2TS"
        err "        也可以用环境变量:  export TIMESTAMP_URL=http://timestamp.digicert.com"
        err "     3. 临时网络问题：等几分钟重跑"
        exit 1
    fi
    # 其他错误：把 stderr 透传给调用方处理（继续走 --no-strict fallback 等）
    cat "$err_log" >&2
    rm -f "$err_log"
    return 1
}

if [[ $NOTARIZE_ONLY -eq 0 ]]; then
    info "签名嵌套组件..."

    FW="$APP_PATH/Contents/Frameworks"
    MAIN_BIN="$APP_PATH/Contents/MacOS/$APP_NAME"

    if [[ -d "$FW" ]]; then
        # 1) helper app 主二进制
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing helper main: $f"
            do_codesign "$f" --entitlements "$ENTITLEMENTS" || warn "   helper main 签名失败: $f"
        done < <(find "$FW" -path "*.app/Contents/MacOS/*" -type f 2>/dev/null | sort)

        # 2) 扫描 framework 内部 Mach-O (优化：避开 Current 链接，扩充过滤名单)
        info "  扫描 framework Mach-O 二进制..."
        MACHO_LIST=$(mktemp -t macho.XXXXXX)
        find "$FW" -type f -path "*/Versions/*" ! -path "*/Versions/Current/*" 2>/dev/null | while IFS= read -r ff; do
            [[ -L "$ff" ]] && continue
            case "$ff" in
                *.app/Contents/MacOS/*) continue ;;
            esac
            case "$ff" in
                */Info.plist|*.plist|*.txt|*.html|*.json|*.png|*.icns|*.strings|*.pak|*.bin|*.dat|*.nib|*.v8_context_snapshot) continue ;;
                *.lproj/*|*/_CodeSignature/*) continue ;;
            esac
            if file -b "$ff" 2>/dev/null | grep -q "Mach-O"; then
                echo "$ff" >>"$MACHO_LIST"
            fi
        done

        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing macho: $f"
            if ! do_codesign "$f"; then
                warn "   retry with --no-strict: $f"
                codesign --force --no-strict --options=runtime "${TS_FLAGS[@]}" \
                    --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" "$f" || warn "   macho 签名最终失败: $f"
            fi
        done < <(awk -F/ '{print NF, $0}' "$MACHO_LIST" | sort -rn | cut -d' ' -f2-)
        rm -f "$MACHO_LIST"

        # 3) helper .app 顶层
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing helper app: $f"
            do_codesign "$f" || warn "   helper 签名失败: $f"
        done < <(find "$FW" -maxdepth 2 -name "*.app" -type d 2>/dev/null | sort)

        # 4) framework 顶层
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing framework bundle: $f"
            if ! do_codesign "$f"; then
                warn "   retry with --no-strict: $f"
                codesign --force --no-strict --options=runtime "${TS_FLAGS[@]}" \
                    --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" "$f" || warn "   framework 签名最终失败: $f"
            fi
        done < <(find "$FW" -maxdepth 2 -name "*.framework" 2>/dev/null | sort)
    fi

    # 5) 主二进制
    [[ ! -f "$MAIN_BIN" ]] && { err "找不到主二进制: $MAIN_BIN"; exit 1; }
    info "签名主二进制 (含 entitlements): $MAIN_BIN"
    do_codesign "$MAIN_BIN" --entitlements "$ENTITLEMENTS" || { err "主二进制签名失败"; exit 1; }

    # 6) 主 App 顶层
    info "签名主 App: $APP_PATH"
    do_codesign "$APP_PATH" || { err "主 App 签名失败"; exit 1; }

    # 7) 冒烟自检
    info "本机 verify..."
    VERIFY_LOG=$(mktemp -t csverify.XXXXXX)
    if codesign --verify --verbose=2 "$APP_PATH" >"$VERIFY_LOG" 2>&1; then
        ok "verify 通过"
    elif grep -q "bundle format is ambiguous" "$VERIFY_LOG" \
        && ! grep -qE "not signed at all|invalid signature|rejected|code object is not signed|does not include a secure timestamp" "$VERIFY_LOG"; then
        warn "verify 仅报 'bundle format is ambiguous'，Apple notarytool 通常接受。"
    else
        cat "$VERIFY_LOG" >&2
        rm -f "$VERIFY_LOG"
        err "本机 verify 失败，请排查包结构"
        exit 1
    fi
    rm -f "$VERIFY_LOG"

    # 8) 关键 entitlement 自检：少了这 4 条里任意一条，
    #    Electron 主进程会在 v8::Context::FromSnapshot 阶段 SIGTRAP 崩（brk 0），
    #    现象是打开 .app 立刻闪退，crashlog 栈停在 ElectronMain + 200 左右。
    #    提前在这里 fail-fast，比打包公证完再被打回来省时间。
    #
    #    ⚠️ 注意要读主二进制（$MAIN_BIN）而不是 .app bundle（$APP_PATH），
    #    因为步骤 5 签主二进制时传了 --entitlements，步骤 6 签 .app 时没传，
    #    所以 .app 的 signature 里 entitlements 是空的，必须读主二进制。
    info "entitlement 自检..."
    REQUIRED_ENTS=(
        "com.apple.security.cs.allow-jit"
        "com.apple.security.cs.allow-unsigned-executable-memory"
        "com.apple.security.cs.allow-dyld-environment-variables"
        "com.apple.security.cs.disable-library-validation"
    )
    # 主二进制是 entitlements 实际签名的地方
    DUMPED_ENTS=$(codesign -d --entitlements - --xml "$MAIN_BIN" 2>/dev/null)
    if [[ -z "$DUMPED_ENTS" ]]; then
        # 兜底：某些工作流把 entitlements 放在 .app 上
        DUMPED_ENTS=$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null)
    fi
    MISSING_ENTS=()
    for k in "${REQUIRED_ENTS[@]}"; do
        if ! grep -qF "$k" <<<"$DUMPED_ENTS"; then
            MISSING_ENTS+=("$k")
        fi
    done
    if [[ ${#MISSING_ENTS[@]} -gt 0 ]]; then
        err "以下关键 entitlement 缺失，会导致打开 .app 立刻 SIGTRAP 崩溃："
        for k in "${MISSING_ENTS[@]}"; do err "  - $k"; done
        err "请在 $ENTITLEMENTS 里补上后重新签名"
        exit 1
    fi
    ok "关键 entitlement 检查通过"

    ok "签名部分完成"
fi

# ---------- 4. 公证 ----------
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    if [[ -n "$AC_API_KEY_PATH" && -z "$AC_API_KEY_ID" ]]; then
        base="$(basename "$AC_API_KEY_PATH")"
        if [[ "$base" =~ AuthKey_([A-Z0-9]+)\.p8 ]]; then
            AC_API_KEY_ID="${BASH_REMATCH[1]}"
            ok "推断 Key ID: $AC_API_KEY_ID"
        fi
    fi

    [[ -n "$AC_API_KEY_PATH" && -f "$AC_API_KEY_PATH" ]] || { err "缺 .p8 AuthKey"; exit 1; }
    [[ -n "$AC_API_KEY_ID" ]]    || { err "缺 Key ID"; exit 1; }
    [[ -n "$AC_API_ISSUER_ID" ]] || { err "缺 Issuer ID"; exit 1; }

    OUT_DIR="$(dirname "$APP_PATH")/dist"
    mkdir -p "$OUT_DIR"
    ZIP_PATH="$OUT_DIR/$APP_NAME.zip"
    NOTARY_JSON="$OUT_DIR/$APP_NAME.notary.json"

    info "打包公证用 zip..."
    # 强制在公证专用的打包环节也保留 symlink
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    ok "zip 完成"

    info "提交公证..."
    NOTARY_RETRY_MAX=${NOTARY_RETRY_MAX:-5}
    NOTARY_RETRY_DELAY=${NOTARY_RETRY_DELAY:-10}
    NOTARY_STATUS=""
    SUBMISSION_ID=""

    for attempt in $(seq 1 $NOTARY_RETRY_MAX); do
        if xcrun notarytool submit "$ZIP_PATH" --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" --wait --output-format json >"$NOTARY_JSON" 2>/tmp/notaryerr.$$; then
            NOTARY_STATUS=$(python3 -c "import json;print(json.load(open('$NOTARY_JSON')).get('status','Unknown'))" 2>/dev/null || echo "Unknown")
            [[ "$NOTARY_STATUS" == "Accepted" ]] && break
            if ! grep -q -E "deadlineExceeded|abortedUpload|network|connection|timeout" /tmp/notaryerr.$$ 2>/dev/null; then break; fi
            warn "网络错误，${NOTARY_RETRY_DELAY}s 后重试"
            sleep "$NOTARY_RETRY_DELAY"
        else
            if grep -q -E "deadlineExceeded|abortedUpload|network|connection|timeout" /tmp/notaryerr.$$ 2>/dev/null; then
                warn "上传超时，${NOTARY_RETRY_DELAY}s 后重试"
                sleep "$NOTARY_RETRY_DELAY"
            else
                cat /tmp/notaryerr.$$
                err "submit 失败"
                break
            fi
        fi
    done
    rm -f /tmp/notaryerr.$$

    SUBMISSION_ID=$(python3 -c "import json;print(json.load(open('$NOTARY_JSON')).get('id',''))" 2>/dev/null || echo "")

    if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
        err "公证失败: $NOTARY_STATUS"
        [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" "$OUT_DIR/$APP_NAME.notarylog.json"
        echo "查看日志: $OUT_DIR/$APP_NAME.notarylog.json"
        exit 1
    fi
    ok "公证 Accepted"

    info "Stapling..."
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    ok "Staple 完成"
fi

echo "============================================="
ok "全部流程完成: $APP_PATH"
echo "============================================="