# macOS 签名 + 公证 + dmg 打包工具集

针对 Electron / 原生 macOS App 的一键签名公证脚本，已按职责拆分为两个互不影响的脚本。

## 包含的脚本

| 脚本 | 职责 | 是否会修改 `.app` |
|---|---|---|
| `sign.sh` | 导入 `.p12`、钥匙串 ACL 授权、签名、校验、提交公证、staple | ✅ |
| `build-dmg.sh` | 给已签名 `.app` 生成带 Finder 拖拽布局的 dmg | ❌（只读） |
| `entitlements.mac.plist` | Electron hardened-runtime entitlements（共用） | — |

两个脚本完全独立，可任意组合或单独使用。

## 环境要求

- macOS
- Xcode Command Line Tools（`xcrun`、`codesign`、`hdiutil`、`sips`）
- Apple Developer ID Application 证书（`.p12` 格式）
- App Store Connect API Key（`.p8` + Key ID + Issuer ID）—— 仅在公证时需要

## 快速开始

### 1. 签名 + 公证

```bash
./scripts/sign.sh \
    --app "WonderHub Class.app" \
    --p12 ~/certs/DeveloperID.p12 \
    --p12-pass 'p12密码' \
    --authkey ~/certs/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer  11111111-2222-3333-4444-555555555555
```

执行后会原地修改 `.app`（签名 + staple），并在 `dist/` 下产出公证日志。

### 2. 打包 dmg

```bash
./scripts/build-dmg.sh
# 自定义背景
./scripts/build-dmg.sh --bg ./assets/dmg-background.png
```

输出 `dist/<AppName>.dmg`，**`.app` 完全不被修改**。

## 详细参数

### `sign.sh`

```
--app <path>           .app 路径（也支持作为位置参数）
--p12 <path>           DeveloperID.p12 路径（会自动导入钥匙串）
--p12-pass <string>    .p12 密码
--authkey <path>       App Store Connect AuthKey_xxx.p8 路径
--key-id <id>          AuthKey Key ID（脚本可从文件名自动推断）
--issuer <uuid>        App Store Connect Issuer ID
--identity <string>    直接指定签名身份（覆盖自动检测）
--skip-notarize        只签名，不公证
--notarize-only        只对当前已签名的 .app 补公证
--test-mode            测试模式：跳过 Developer ID 身份校验，允许 ad-hoc 签名演练
--dry-run              只打印计划，不执行
```

支持环境变量降级：`P12_PATH` / `P12_PASS` / `AC_API_KEY_PATH` / `AC_API_KEY_ID` / `AC_API_ISSUER_ID` / `APP_SIGN_IDENTITY`。

签名身份未提供时，脚本会从钥匙串自动检测 `Developer ID Application:` 身份；多个会交互式让你选。

### `build-dmg.sh`

```
--bg <png>             背景图（推荐 540x380，会自动取其尺寸）
--icon-size <int>      Finder 图标大小（默认 128）
--win-size WxH         窗口尺寸（默认 540x380，--bg 存在时自动覆盖）
[app_path] [dmg_path]  也支持位置参数
```

### 典型工作流

```bash
# CI 友好：全部环境变量驱动
export P12_PATH=/secrets/DeveloperID.p12
export P12_PASS=xxx
export AC_API_KEY_PATH=/secrets/AuthKey_xxx.p8
export AC_API_KEY_ID=xxx
export AC_API_ISSUER_ID=xxx
export APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"

./scripts/sign.sh                 # 签名 + 公证
./scripts/build-dmg.sh            # 打 dmg
```

## 钥匙串 ACL 授权（避免每次弹窗）

macOS 的钥匙串对 codesign / xcodebuild 等工具默认要求密码授权。第一次执行 `sign.sh` 时脚本会**自动探测**，如果发现某个钥匙串需要授权：

1. 列出需要授权的钥匙串（`login` / `build`）
2. 提示运行 `security set-key-partition-list` 一次性命令
3. 询问是否现在输入密码自动设置（设置后永久免密）

### 手动一次设置（无需脚本）

```bash
security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,codesign-create:,security: \
    -s \
    -k "你的登录密码" \
    ~/Library/Keychains/login.keychain-db

# 如果 Developer ID 在 build 钥匙串（Xcode 默认行为）
security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,codesign-create:,security: \
    -s \
    -k "build 钥匙串密码" \
    ~/Library/Keychains/build.keychain-db
```

执行后 codesign / xcodebuild 永久免密访问对应钥匙串。

> 注意：脚本导入 `.p12` 时已带 `-T /usr/bin/codesign -T /usr/bin/security` ACL，
> 通常只要 .p12 是通过 `--p12` 参数导入，codesign 不会再弹窗。
> 弹窗通常发生在**手动**导入或从其他 Mac 迁过来的证书上。

## 多机协作（.p12 在另一台 Mac）

敏感证书不方便导出？推荐在**有证书的 Mac** 上跑全流程，不导出证书。

在有证书的机器上：

```bash
git clone https://github.com/liuyueershihao/mac-sign.git
cd mac-sign
./sign.sh --app /path/to/YourApp.app \
    --p12 <本地.p12> --p12-pass 'xxx' \
    --authkey <本地.p8> --key-id xxx --issuer xxx
./build-dmg.sh /path/to/YourApp.app
```

如果必须导出 .p12 到其他机器：

```bash
# 在源 Mac 上导出（设一个新密码）
security export -k ~/Library/Keychains/login.keychain-db \
    -t identities -f pkcs12 \
    -o ~/Desktop/DeveloperID.p12 \
    -P "传输密码"

# 传到目标机器后用 --p12 导入
./sign.sh --p12 ~/Downloads/DeveloperID.p12 --p12-pass '传输密码' ...
```

## 常见问题

**Q: 弹窗 "codesign 想要使用 build 钥匙串"**
A: Developer ID 证书在 build 钥匙串但 codesign 没 ACL 授权。运行上面的 `set-key-partition-list` 命令一次。

**Q: 本机没有任何 Developer ID Application 身份**
A: `.p12` 没导入成功。运行 `security find-identity -p codesigning -v` 检查；若有 `Apple Development:` 身份但没有 `Developer ID Application:`，说明你导错了证书类型（需要 Distribution 类型的 .p12，不是 Development）。

**Q: AppleScript 控制 Finder 失败 / dmg 没自定义布局**
A: 去 **系统设置 → 隐私与安全性 → 自动化** 给当前终端授权 Finder。授权失败时 dmg 仍能生成，只是不带布局。

**Q: 公证失败 `The binary is not signed with a valid Developer ID certificate`**
A: `.p12` 没导入到当前操作的钥匙串。重跑脚本并加 `--p12`。

**Q: 公证失败 `The signature does not include a secure timestamp`**
A: 没传 `--timestamp`（脚本已内置），检查是否被覆盖。

**Q: 用户首次打开 dmg 仍被 Gatekeeper 拦截**
A: 没成功 staple。重跑 `xcrun stapler staple "YourApp.app"`。

**Q: 报错 `code object is not signed at all`**
A: 签名顺序错。本脚本已按"嵌套从内到外"顺序签名，正常使用不会出现。

**Q: `verify` 失败但脚本仍报"签名完成"**
A: 旧版脚本会静默回退到 `--no-strict`，已重构。新版策略：主二进制和主 .app **完全不碰 `--no-strict`**（保证 slice 签名正确），framework Mach-O / framework 顶层在严格 codesign 报 `bundle format is ambiguous` 时才退到 `--no-strict` 作为兜底（不影响签名内容），并在最后用 `codesign --verify --verbose=2` 冒烟自检（不用 `--strict`，避免 Electron framework 结构警告被误判）。

**Q: 公证失败 `The signature of the binary is invalid`（多个 architecture）**
A: 主 .app 用了 `codesign --deep` 会破坏 universal binary 的 slice 级 code directory。本脚本已改为：先签 Mach-O 单文件，再签 helper / framework / 主二进制 / 主 .app，全程不碰 `--deep`，主二进制独立签一次（带 entitlements）。`--no-strict` 只在 framework 内部严格模式失败时作为兜底，不会作用到主二进制和主 .app。

**Q: framework 报 `bundle format is ambiguous (could be app or framework)`**
A: Electron 的 `Squirrel.framework` / `ReactiveObjC.framework` / `Mantle.framework` / `Electron Framework.framework` 结构对严格 codesign 来说有歧义（顶层 X.framework/X 快捷方式、Info.plist 位置等）。脚本会先严格签，失败时自动用 `--no-strict` 重试，Apple notarytool 接受这种结构（只会产生 `Unable to notarize` 警告，不影响通过）。

**Q: 公证通过，但打开 .app 立刻闪退，crashlog 是 `EXC_BREAKPOINT (SIGTRAP)` / `brk 0`，栈停在 `ElectronMain + 200` / `v8::Context::FromSnapshot`**
A: V8 启动时要把 `v8_context_snapshot.bin` 加载进 isolate，hardened runtime 模式下需要 `com.apple.security.cs.allow-dyld-environment-variables`，缺了 V8 的 DCHECK 触发 `__builtin_trap()` 直接 SIGTRAP 杀进程。本脚本在签完后会读回 entitlements 校验这 4 条（`allow-jit` / `allow-unsigned-executable-memory` / `allow-dyld-environment-variables` / `disable-library-validation`），少哪条都会在签名阶段立刻报错，不会跑到公证完才发现闪退。如果校验被跳过/绕过，记得检查 `entitlements.mac.plist` 里有 `cs.allow-dyld-environment-variables`（Electron 官方文档明确列为必需）。