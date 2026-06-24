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
    MAIN_BIN="$APP_PATH/Contents/MacOS/$APP_NAME"

    # ----------------------------------------------------------------
    # 关键原则：不要在任何地方用 --deep
    #   --deep 会让 codesign 重写 universal binary 的 slice 级 code directory，
    #   写出来的东西跟 bundle 的 CodeResources 对不上，本地 --no-strict 看不出来，
    #   Apple notary 严格校验就会判 "The signature of the binary is invalid"。
    # 正确顺序：Mach-O 单文件 -> 内层 bundle -> 外层 bundle，逐层向外签。
    # ----------------------------------------------------------------

    if [[ -d "$FW" ]]; then
        # 1) helper app 的主二进制（路径形如 .../XXX.app/Contents/MacOS/XXX）
        #    先单独签，给 entitlements，让 helper 的 CodeResources 抓的是带 entitlements 的 hash
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing helper main: $f"
            codesign --force --options=runtime --timestamp \
                --entitlements "$ENTITLEMENTS" \
                --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
                "$f" || warn "   helper main 签名失败: $f"
        done < <(find "$FW" -path "*.app/Contents/MacOS/*" -type f 2>/dev/null | sort)

        # 2) 扫描 framework 内部 Mach-O（不含 helper main，已在步骤 1 签过）
        #    同时跳过符号链接：framework 顶层 X.framework/X 是指向
        #    X.framework/Versions/A/X 的 symlink，再签一次会重复且会在 notary
        #    那边产生 "Unable to notarize" 警告
        info "  扫描 framework Mach-O 二进制..."
        MACHO_LIST=$(mktemp -t macho.XXXXXX)
        find "$FW" -type f 2>/dev/null | while IFS= read -r ff; do
            # 符号链接直接跳过（指向已签过的真实文件）
            [[ -L "$ff" ]] && continue
            # helper 主二进制已在步骤 1 签过，这里别再动它
            case "$ff" in
                *.app/Contents/MacOS/*) continue ;;
            esac
            # 明显非 Mach-O 的资源
            case "$ff" in
                */Info.plist|*.plist|*.txt|*.html|*.json|*.png|*.icns|*.strings|*.pak|*.bin) continue ;;
                *.lproj/*) continue ;;
                */_CodeSignature/*) continue ;;
            esac
            if file -b "$ff" 2>/dev/null | grep -q "Mach-O"; then
                echo "$ff" >>"$MACHO_LIST"
            fi
        done

        # 按目录深度从深到浅排序（先签最深的）
        # 部分 Electron framework 的 .framework/X 顶层快捷方式在严格模式下会报
        # "bundle format is ambiguous"，这种时候退到 --no-strict（不影响签名内容）
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing macho: $f"
            if ! codesign --force --options=runtime --timestamp \
                --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
                "$f"; then
                warn "   retry with --no-strict: $f"
                codesign --force --no-strict --options=runtime --timestamp \
                    --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
                    "$f" || warn "   macho 签名最终失败: $f"
            fi
        done < <(awk -F/ '{print NF, $0}' "$MACHO_LIST" | sort -rn | cut -d' ' -f2-)
        rm -f "$MACHO_LIST"

        # 3) helper .app 顶层（不再用 --deep，内部主二进制已签好）
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing helper app: $f"
            codesign --force --options=runtime --timestamp \
                --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
                "$f" || warn "   helper 签名失败: $f"
        done < <(find "$FW" -maxdepth 2 -name "*.app" -type d 2>/dev/null | sort)

        # 4) framework 顶层（不再用 --deep，内部 Mach-O 已签好）
        #    Electron 的 framework 同样有 "bundle format is ambiguous" 问题，退到 --no-strict
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "   signing framework bundle: $f"
            if ! codesign --force --options=runtime --timestamp \
                --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
                "$f"; then
                warn "   retry with --no-strict: $f"
                codesign --force --no-strict --options=runtime --timestamp \
                    --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
                    "$f" || warn "   framework 签名最终失败: $f"
            fi
        done < <(find "$FW" -maxdepth 2 -name "*.framework" 2>/dev/null | sort)
    fi

    # 5) 主二进制：单独签一次（带 entitlements）
    #    绝对不能用 --deep 走整个 .app，否则 universal binary 的 slice 签名会再次被破坏
    if [[ ! -f "$MAIN_BIN" ]]; then
        err "找不到主二进制: $MAIN_BIN"
        exit 1
    fi
    info "签名主二进制 (含 entitlements): $MAIN_BIN"
    codesign --force --options=runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
        "$MAIN_BIN" || { err "主二进制签名失败"; exit 1; }

    # 6) 主 .app 顶层：内部全部已签好，这里只签 bundle 本身
    info "签名主 App: $APP_PATH"
    codesign --force --options=runtime --timestamp \
        --sign "$APP_SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
        "$APP_PATH" || { err "主 App 签名失败"; exit 1; }

    # 7) 冒烟自检：本机跑一次 verify。
    #    codesign --verify 即便不用 --strict，碰到 Electron 那种 .framework/X
    #    顶层快捷方式时也会以非零退出码报 "bundle format is ambiguous"。
    #    这个是上游打包工具产出的结构问题，Apple notarytool 接受。
    #    我们的策略：跑 verify，如果退出码非零，但输出里只有这一个无害警告，
    #    就当 warn 放过；只有出现真正的签名错误才 fail-fast。
    info "本机 verify..."
    VERIFY_LOG=$(mktemp -t csverify.XXXXXX)
    if codesign --verify --verbose=2 "$APP_PATH" >"$VERIFY_LOG" 2>&1; then
        ok "verify 通过"
    elif grep -q "bundle format is ambiguous" "$VERIFY_LOG" \
        && ! grep -qE "not signed at all|invalid signature|rejected|code object is not signed|does not include a secure timestamp" "$VERIFY_LOG"; then
        warn "verify 仅报 'bundle format is ambiguous'（Electron framework 固有问题，Apple notarytool 接受）："
        sed 's/^/      /' "$VERIFY_LOG"
    else
        cat "$VERIFY_LOG" >&2
        rm -f "$VERIFY_LOG"
        err "本机 verify 失败，请勿提交公证"
        exit 1
    fi
    rm -f "$VERIFY_LOG"

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
    NOTARY_JSON="$OUT_DIR/$APP_NAME.notary.json"

    info "打包 zip..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    ok "zip 完成"

    info "提交公证..."
    NOTARY_RETRY_MAX=${NOTARY_RETRY_MAX:-5}
    NOTARY_RETRY_DELAY=${NOTARY_RETRY_DELAY:-10}
    NOTARY_STATUS=""
    SUBMISSION_ID=""

    for attempt in $(seq 1 $NOTARY_RETRY_MAX); do
        if xcrun notarytool submit "$ZIP_PATH" \
            --key "$AC_API_KEY_PATH" \
            --key-id "$AC_API_KEY_ID" \
            --issuer "$AC_API_ISSUER_ID" \
            --wait \
            --output-format json >"$NOTARY_JSON" 2>/tmp/notaryerr.$$; then
            NOTARY_STATUS=$(python3 -c "import json;print(json.load(open('$NOTARY_JSON')).get('status','Unknown'))" 2>/dev/null || echo "Unknown")
            if [[ "$NOTARY_STATUS" == "Accepted" ]]; then
                break
            fi
            # 非网络错误（如 Invalid）直接退出
            if ! grep -q -E "deadlineExceeded|abortedUpload|network|connection|timeout" /tmp/notaryerr.$$ 2>/dev/null; then
                break
            fi
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