#!/usr/bin/env bash
# mac-sign 诊断脚本：收集所有签名状态信息
# 用法：bash scripts/diagnose.sh

set +e
APP="${1:-./whc-app-web/WonderHub Class.app}"

echo "============================================="
echo "1. 当前代码版本"
echo "============================================="
git log --oneline -1 2>/dev/null
git status -sb 2>/dev/null | head -3
echo

echo "============================================="
echo "2. App 是否存在"
echo "============================================="
ls -la "$APP" 2>&1 | head -3
echo

echo "============================================="
echo "3. 主二进制签名状态（关键）"
echo "============================================="
MAIN="$APP/Contents/MacOS/WonderHub Class"
echo "文件: $MAIN"
ls -la "$MAIN"
echo
echo "--- file 类型 ---"
file "$MAIN"
echo
echo "--- codesign -dvv ---"
codesign -dvv "$MAIN" 2>&1
echo

echo "============================================="
echo "4. 框架 Mach-O 签名状态"
echo "============================================="
FW="$APP/Contents/Frameworks"
for fw in "Electron Framework.framework" "Squirrel.framework" "ReactiveObjC.framework" "Mantle.framework"; do
    MAIN_FW="$FW/$fw"
    echo "--- $fw ---"
    file "$MAIN_FW" 2>&1
    codesign -dvv "$MAIN_FW" 2>&1 | head -10
    echo
done

echo "============================================="
echo "5. 钥匙串里的 Developer ID 身份"
echo "============================================="
security find-identity -p codesigning -v 2>&1 | head -10
echo

echo "============================================="
echo "6. 主 .app 签名状态"
echo "============================================="
codesign -dvv "$APP" 2>&1
echo

echo "============================================="
echo "7. Helper apps 签名状态（这些应该 OK）"
echo "============================================="
for helper in "$FW"/WonderHub\ Class\ Helper*.app; do
    echo "--- $(basename "$helper") ---"
    codesign -dvv "$helper" 2>&1 | head -5
done