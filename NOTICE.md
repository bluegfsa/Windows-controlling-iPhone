# NOTICE — 第三方组件与上游声明

本项目（PhoneKit）是在多个优秀开源项目之上组装、修补并工程化的结果。以下是各组件的来源与协议：

## 1. SideTap（引擎源码）
- 来源：https://github.com/ucsandman/SideTap
- 协议：MIT License，Copyright (c) 2026 Wes Sander
- 用法：`src/phone_harness/` 目录基于其源码，包含本项目的 Windows 兼容性修改
  （GBK 解码回退、netstat/tasklist 输出为 None 的容错等，见 `kitpatch.py`）
- 上游原始文档备份在 `upstream/` 目录

## 2. go-ios（iOS USB 通信）
- 来源：https://github.com/danielpaulus/go-ios
- 协议：MIT License
- 用法：`bin/ios.exe`（v1.3.2 编译产物），负责 usbmux/隧道/安装 App/签名等底层操作

## 3. Wintun（iOS 17+ 隧道依赖）
- 来源：https://www.wintun.net/
- 用法：`bin/wintun.dll`，按其许可随软件再分发；iOS 17+ 的 userspace 隧道需要它

## 4. WebDriverAgent（手机端控制服务）
- 来源：https://github.com/appium/WebDriverAgent
- 用法：本仓库**不包含** WDA 的 ipa 文件。请运行 `python wda/make_ipa.py`
  从上游 release 自动下载并生成可签名的未签名 ipa，然后用你自己的
  Apple ID / 开发者证书通过 Sideloadly 等工具签名安装（步骤见 `docs/02-从零部署.md`）。

## 仓库刻意不包含的内容
- **已签名的 ipa**：签名包内嵌个人开发者证书与 profile，发布即泄露
- **selfIdentity.plist**：go-ios 的本机配对私钥，属于设备信任凭据
- **任何 UDID / Team ID**：文档与示例中的相关字段均以 `YOUR_UDID` / `YOUR_TEAM_ID` 占位

## 与本项目无关的说明
PhoneKit 与 iPhoneMirror、爱思助手、任何投屏/镜像软件无关：
不录屏、不模拟鼠标键盘、不需要窗口在前台，控制链路是纯 HTTP（WDA）。
