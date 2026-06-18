# macOS 签名 + 公证 + dmg 打包工具集

针对 Electron / 原生 macOS App 的一键签名公证脚本，已按职责拆分为两个互不影响的脚本。

## 包含的脚本

| 脚本 | 职责 | 是否会修改 `.app` |
|---|---|---|
| `sign.sh` | 导入 `.p12`、签名、校验、提交公证、staple | ✅ |
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

## 常见问题

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