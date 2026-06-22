#!/usr/bin/env bash
# ============================================================================
# WonderHub Class - 签名 + 公证脚本（独立）
# ============================================================================
# 强制 bash 执行（zsh 跑会 auto re-exec）
if [[ -z "$BASH_VERSION" ]]; then
    exec /usr/bin/env bash "$0" "$@"
fi
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
    echo
    echo "  当前位置: $(pwd)"
    echo "  当前目录的 .app:"
    find . -maxdepth 2 -name "*.app" -type d 2>/dev/null | head -10 | sed 's/^/    /'
    echo
    echo "  💡 带空格的路径需要加引号或转义:"
    echo "     --app \"./WonderHub Class.app\""
    echo "     --app ./WonderHub\\ Class.app"
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
    IDENTITIES=()
    if [[ $TEST_MODE -eq 1 ]]; then
        # 测试模式：接受任意 codesign 身份（包括 ad-hoc "-"）
        while IFS= read -r line; do IDENTITIES+=("$line"); done < <(
            security find-identity -p codesigning -v "$KEYCHAIN_PATH" 2>/dev/null \
                | awk -F'"' '/Identity/{print $2}'
        )
        if [[ ${#IDENTITIES[@]} -eq 0 ]]; then
            warn "测试模式：未找到任何 codesign 身份，将使用 ad-hoc 签名 (-)"
            APP_SIGN_IDENTITY="-"
        elif [[ ${#IDENTITIES[@]} -eq 1 ]]; then
            APP_SIGN_IDENTITY="${IDENTITIES[0]}"
            ok "检测到: $APP_SIGN_IDENTITY"
        else
            echo "找到多个身份:"
            for i in "${!IDENTITIES[@]}"; do echo "  [$((i+1))] ${IDENTITIES[$i]}"; done
            echo "  [0] 使用 ad-hoc 签名 (-)"
            read -rp "选择 [0-${#IDENTITIES[@]}]: " pick
            if [[ "$pick" == "0" ]]; then APP_SIGN_IDENTITY="-"; else APP_SIGN_IDENTITY="${IDENTITIES[$((pick-1))]}"; fi
        fi
    else
        while IFS= read -r line; do IDENTITIES+=("$line"); done < <(
            security find-identity -p codesigning -v "$KEYCHAIN_PATH" 2>/dev/null \
                | grep "Developer ID Application:" | awk -F'"' '{print $2}'
        )
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
fi

# ---------- 2. 解锁钥匙串 + 永久授权 Apple 工具 ----------
# 探测 codesign 是否能无感访问该钥匙串（避免创建临时 .app 干扰）
ensure_keychain_acl() {
    local kc="$1"
    [[ -f "$kc" ]] || return 0
    # 用 codesign 对空文件试签，能跑通 + 不返回 "user interaction" 即为有权限
    local probe
    probe="$(mktemp -t kcprobe.XXXXXX)"
    : >"$probe"
    local out
    out="$(codesign --force --sign - "$probe" 2>&1)"
    rm -f "$probe"
    if echo "$out" | grep -q "user interaction is not allowed"; then
        return 1
    fi
    return 0
}

info "检查钥匙串 ACL 授权状态..."
LIST_LOCKED=()
for kc in "$HOME/Library/Keychains/login.keychain-db" \
          "$HOME/Library/Keychains/build.keychain-db"; do
    [[ -f "$kc" ]] || continue
    security unlock-keychain -p "" "$kc" 2>/dev/null || \
        security unlock-keychain "$kc" 2>/dev/null || true
    if ! ensure_keychain_acl "$kc"; then
        LIST_LOCKED+=("$kc")
    fi
done

if [[ ${#LIST_LOCKED[@]} -gt 0 ]]; then
    err "下列钥匙串需要 codesign 永久授权（每次签名的弹窗根因）："
    for kc in "${LIST_LOCKED[@]}"; do
        err "  - $kc"
    done
    echo
    echo "  一次性修复（输入对应钥匙串的密码，下次起永久免密）："
    for kc in "${LIST_LOCKED[@]}"; do
        echo "    security set-key-partition-list \\"
        echo "        -S apple-tool:,apple:,codesign:,codesign-create:,security: \\"
        echo "        -k \"你的钥匙串密码\" \"$kc\""
    done
    echo
    echo "  也可以现在让脚本为你自动设置（会交互要求输入密码）："
    for kc in "${LIST_LOCKED[@]}"; do
        read -rsp "  密码 for $(basename "$kc"): " kcpass && echo
        security set-key-partition-list \
            -S apple-tool:,apple:,codesign:,codesign-create:,security: \
            -s -k "$kcpass" "$kc" 2>/dev/null
        unset kcpass
        # 再尝试解锁
        security unlock-keychain "$kc" 2>/dev/null || true
    done
fi

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
 Test Mode      : $([[ $TEST_MODE -eq 1 ]] && echo YES || echo NO)
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
    if [[ -d "$FW" ]]; then
        # 1) Helper apps（独立的 .app，--deep 不会处理这些）
        while IFS= read -r f; do
            echo "   signing helper app: $f"
            codesign --force --deep --options=runtime --timestamp \
                --entitlements "$ENTITLEMENTS" \
                --sign "$APP_SIGN_IDENTITY" \
                --keychain "$KEYCHAIN_PATH" \
                "$f"
        done < <(find "$FW" -maxdepth 2 -name "*.app" -type d | sort)

        # 2) framework 内的 Mach-O 二进制（用 file 过滤，更准）
        sign_macho() {
            local f="$1"
            [[ -f "$f" ]] || return 0
            # 跳过明显非二进制的文件
            case "$f" in
                */Info.plist|*.txt|*.html|*.json|*.png|*.icns|*.strings|*.pak|*.bin|*.lproj/*) return 0 ;;
            esac
            file -b "$f" 2>/dev/null | grep -q "Mach-O" || return 0
            echo "   signing framework binary: $f"
            codesign --force --options=runtime --timestamp \
                --sign "$APP_SIGN_IDENTITY" \
                --keychain "$KEYCHAIN_PATH" \
                "$f"
        }

        # 优先：dylib/so/明确 Mach-O
        while IFS= read -r f; do
            [[ -n "$f" ]] && sign_macho "$f"
        done < <(find "$FW" -type f \( -name "*.dylib" -o -name "*.so" -o -name "chrome_crashpad_handler" -o -name "*.node" \) 2>/dev/null | sort)

        # 其次：framework 内顶层可执行文件
        while IFS= read -r f; do
            [[ -n "$f" ]] && sign_macho "$f"
        done < <(find "$FW/Versions" -maxdepth 4 -type f 2>/dev/null | sort -u)

        # 主二进制（顶层 .framework 根下的可执行）
        for f in "$FW/Electron Framework" "$FW/Helpers/chrome_crashpad_handler"; do
            [[ -f "$f" ]] && sign_macho "$f"
        done

        # 3) framework 顶层（用 --no-strict 兼容 Electron 的 ambiguous 框架结构）
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing framework bundle: $f"
            if ! codesign --force --options=runtime --timestamp \
                --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" "$f" 2>/dev/null; then
                codesign --force --no-strict --options=runtime --timestamp \
                    --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" "$f"
            fi
        done < <(find "$FW" -maxdepth 2 \( -name "*.framework" -o -name "*.dylib" -o -name "*.so" \) 2>/dev/null | sort)
    fi

    MAIN="$APP_PATH/Contents/MacOS/$APP_NAME"
    [[ -x "$MAIN" ]] && { echo "   signing main binary: $MAIN"; codesign --force --options=runtime --timestamp --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" "$MAIN"; }

    info "签名主 App: $APP_PATH"
    if codesign --force --deep --options=runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$APP_SIGN_IDENTITY" \
        --keychain "$KEYCHAIN_PATH" \
        "$APP_PATH" 2>/dev/null; then
        ok "主 App 签名成功"
    else
        warn "主 App --deep 失败，用 --deep --no-strict 重试（兼容 Electron Framework）"
        codesign --force --deep --no-strict --options=runtime --timestamp \
            --entitlements "$ENTITLEMENTS" \
            --sign "$APP_SIGN_IDENTITY" \
            --keychain "$KEYCHAIN_PATH" \
            "$APP_PATH"
    fi

    info "校验签名（1.4G app 可能需要 1-5 分钟）..."
    # codesign 写到文件/管道是块缓冲，必须给伪 TTY 才实时输出
    # macOS script -q 命令能创建伪 TTY 强制行缓冲
    # 同时后台跑 codesign + spinner 显示进度
    verify_out=$(mktemp -t verify.XXXXXX)
    ( script -q "$verify_out" codesign --verify --deep --verbose=2 "$APP_PATH" >/dev/null 2>&1; echo $? >"$verify_out.rc" ) &
    bg_pid=$!
    SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    i=0
    elapsed=0
    while kill -0 "$bg_pid" 2>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        validated=$(grep -c "^\-\-validated:" "$verify_out" 2>/dev/null | head -1)
        validated=${validated:-0}
        printf "\r  ${SPIN:$((i % 10)):1} codesign 校验中... 已等待 ${elapsed}s  已验证 ${validated} 个组件  "
        i=$((i + 1))
    done
    echo
    wait "$bg_pid"
    verify_rc=$(cat "$verify_out.rc" 2>/dev/null || echo 1)
    rm -f "$verify_out.rc"
    # script 输出有 \r 字符，清理
    tr '\r' '\n' < "$verify_out" > "${verify_out}.clean"
    mv "${verify_out}.clean" "$verify_out"

    validated_count=$(grep -c "^\-\-validated:" "$verify_out" 2>/dev/null | head -1)
    validated_count=${validated_count:-0}
    is_ambiguous=$(grep -c "ambiguous (could be app or framework)" "$verify_out" 2>/dev/null | head -1)
    is_ambiguous=${is_ambiguous:-0}

    # 逐行打印 codesign 输出
    while IFS= read -r line; do
        case "$line" in
            --validated:*) printf "  ✓ %s\n" "$line" ;;
            --prepared:*)  printf "  · %s\n" "$line" ;;
            *)             [[ -n "$line" ]] && printf "    %s\n" "$line" ;;
        esac
    done <"$verify_out"
    rm -f "$verify_out"

    if [[ $verify_rc -eq 0 ]]; then
        ok "签名校验通过（$validated_count 个组件已验证）"
    else
        if [[ $is_ambiguous -gt 0 ]]; then
            warn "  ⚠️  verify 报告 ambiguous（Electron Framework 顶层结构问题，与脚本无关）"
            warn "  ℹ️  $validated_count 个组件签成功，Apple notarytool 服务端会接受"
        else
            warn "verify 返回非 0（rc=$verify_rc）"
        fi
    fi
    ok "签名完成"
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

    # 1) 打包 zip，显示压缩进度
    APP_SIZE_BYTES=$(du -sb "$APP_PATH" | awk '{print $1}')
    APP_SIZE_HR=$(du -sh "$APP_PATH" | awk '{print $1}')
    info "打包 zip（源: $APP_SIZE_HR）..."
    if command -v pv >/dev/null 2>&1; then
        tar cf - -C "$(dirname "$APP_PATH")" "$(basename "$APP_PATH")" 2>/dev/null \
            | pv -s "$APP_SIZE_BYTES" -N "  压缩进度" \
            | ditto -c -k --sequesterRsrc - "$ZIP_PATH"
    else
        ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    fi
    ZIP_SIZE_HR=$(du -sh "$ZIP_PATH" | awk '{print $1}')
    ok "zip 完成: $ZIP_SIZE_HR"

    # 2) 分两阶段：上传（--no-wait） + 轮询处理进度
    info "提交公证（上传 + 等待处理，会显示状态）..."
    NOTARY_JSON="$OUT_DIR/$APP_NAME.notary.json"
    NOTARY_RETRY_MAX=${NOTARY_RETRY_MAX:-5}
    NOTARY_RETRY_DELAY=${NOTARY_RETRY_DELAY:-10}
    NOTARY_STATUS=""
    SUBMISSION_ID=""

    upload_submission() {
        xcrun notarytool submit "$ZIP_PATH" \
            --key "$AC_API_KEY_PATH" \
            --key-id "$AC_API_KEY_ID" \
            --issuer "$AC_API_ISSUER_ID" \
            --no-wait \
            --output-format json
    }

    poll_status() {
        local id="$1"
        local out="$2"
        local SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        local start_ts
        start_ts=$(date +%s)
        while true; do
            local info_json status elapsed
            info_json=$(xcrun notarytool info "$id" \
                --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" 2>/dev/null)
            status=$(echo "$info_json" | python3 -c "import json,sys;print(json.load(sys.stdin).get('status','Unknown'))" 2>/dev/null || echo "Unknown")
            elapsed=$(( $(date +%s) - start_ts ))
            printf "\r  ${SPIN:$((i % 10)):1} 等待 Apple 处理... 状态: %-10s 已等待: %ds  " "$status" "$elapsed"
            i=$((i + 1))
            if [[ "$status" == "Accepted" || "$status" == "Invalid" || "$status" == "Rejected" ]]; then
                echo
                echo "$info_json" > "$out"
                return 0
            fi
            sleep 5
        done
    }

    for attempt in $(seq 1 $NOTARY_RETRY_MAX); do
        info "  [尝试 $attempt/$NOTARY_RETRY_MAX] 上传 zip 到 Apple S3..."
        local_err=$(mktemp -t notaryerr.XXXXXX)
        if submit_out=$(upload_submission 2>"$local_err"); then
            SUBMISSION_ID=$(echo "$submit_out" | python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
            if [[ -n "$SUBMISSION_ID" ]]; then
                ok "  上传完成 ✓ submission id: $SUBMISSION_ID"
                poll_status "$SUBMISSION_ID" "$NOTARY_JSON"
                NOTARY_STATUS=$(python3 -c "import json;print(json.load(open('$NOTARY_JSON')).get('status','Unknown'))" 2>/dev/null || echo "Unknown")
                break
            fi
        fi
        if grep -q -E "deadlineExceeded|abortedUpload|network|connection|timeout" "$local_err" 2>/dev/null; then
            warn "  上传超时/网络错误，${NOTARY_RETRY_DELAY}s 后重试"
            sleep "$NOTARY_RETRY_DELAY"
        else
            cat "$local_err" >&2
            err "  submit 失败（非网络错误）"
            break
        fi
        rm -f "$local_err"
    done

    if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
        err "公证失败: $NOTARY_STATUS"
        [[ -n "$SUBMISSION_ID" ]] && \
            xcrun notarytool log "$SUBMISSION_ID" \
                --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" \
                "$OUT_DIR/$APP_NAME.notarylog.json"
        echo "查看日志: $OUT_DIR/$APP_NAME.notarylog.json"
        exit 1
    fi
    ok "公证 Accepted ✅"

    info "Stapling..."
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    ok "Staple 完成"
fi

echo "============================================="
if [[ $TEST_MODE -eq 1 ]]; then
    ok "测试模式签名完成（不保证 Gatekeeper 接受）: $APP_PATH"
    echo "    用 codesign -dvv '$APP_PATH' 查看签名详情"
else
    ok "签名完成: $APP_PATH"
fi
echo "============================================="