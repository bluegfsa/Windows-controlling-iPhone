# 01 · 原理：为什么是 WDA，链路到底长什么样

## 1. 整条链路

```
┌─────────────── PC (Windows) ───────────────┐
│                                            │
│  phone.cmd  ──►  phone.py  ──►  phone_harness（Python 库）
│                    │                    │
│                    │                    ├─ HTTP ─► 127.0.0.1:8100  ← WDA
│                    │                    │            （iPhone 上的服务）
│                    │                    └─ 截图备份通道 127.0.0.1:9100
│                    │
│              service.py（常驻）
│                    ├─ ios.exe forward 8100 → 手机 8100
│                    ├─ ios.exe forward 9100 → 手机 9100
│                    └─ ios.exe tunnel start（iOS 17+ 必需）
│                                │
└────────────────────────────────┼───────────────────────────┘
                                 │ USB（Apple usbmux，端口 27015）
                          ┌──────▼──────┐
                          │   iPhone    │
                          │  WebDriverAgentRunner（XCTest 进程）
                          │   ├ /status      健康
                          │   ├ /session    会话
                          │   ├ /source     accessibility 树（XML/JSON）
                          │   ├ /screenshot PNG
                          │   └ /wda/tap|keys|drag  合成触摸/按键
                          └─────────────┘
```

四层，缺一层就动不了：

| 层 | 组件 | 挂了会怎样 |
|---|---|---|
| 1 USB | Apple Mobile Device 驱动 + usbmuxd（iTunes/Apple Devices 自带） | `ios list` 返回空 `deviceList` |
| 2 通道 | `ios.exe`（go-ios 1.3.2） | 能看到设备但连不上服务 |
| 3 隧道 | `ios tunnel start` + `wintun.dll`（**iOS 17+ 才需要**） | 隧道报 `Error loading wintun.dll` / RSD 握手失败 |
| 4 输入输出 | WebDriverAgent（手机上的 App，需签名安装） | `:8100/status` 不通；截图可能还能用，但点不了 |

## 2. 端口与状态文件

| 位置 | 用途 |
|---|---|
| `127.0.0.1:8100` | WDA HTTP API（唯一驱动入口） |
| `127.0.0.1:9100` | MJPEG 视频流（本包不用，留着给可视化面板） |
| `127.0.0.1:8899` | PhoneKit 控制 API：`GET /health`、`POST /up`、`POST /down` |
| `28100` | go-ios 隧道 agent 端口（**不能**用默认 60105，见 04 文档） |
| `.state/wda_session` | 会话 id 缓存——跨进程复用，省掉每次 `POST /session` 的 1~2 秒 |
| `.state/runwda.log` | WDA 启动日志（启动失败先看它） |
| `artifacts/service.log` | 常驻服务日志 |

## 3. 三个让它"准"的设计

### 3.1 元素树优先，坐标兜底

`/source` 返回的是 iOS accessibility 树：每个节点有 `type`（Button/StaticText/TextField/Image）、`label`、`frame`。
所以 `tap-text "开始导航"` 是**按标签找真元素**，不是按像素猜。树里的 `frame` 就是 OCR 的 `x/y` 来源，两者同源、互相校验。

### 3.2 坐标系：逻辑点，不是像素

iPhone 13 物理 1170×2532，缩放 3×，**逻辑 390×844**。
WDA 的 tap 和 OCR 的坐标都用逻辑点——所以 `y=792` 是"底部导航按钮"，`y=74` 是"标题栏"，不需要你换算。

> 反面教材：早期用投屏截图（PNG 197×428 这种裁剪图）算坐标，按钮和坐标对不上，点 10 次错 4 次。改成"OCR bounds 直接用"后一次命中。

### 3.3 用文字判状态，不用 sleep

```
改前：tap → sleep 2 → 截图 → 人眼看
改后：tap → wait_text("路线偏好") → 继续      ← 通常 0.4~0.8 秒就返回
```

`wait_stable()` 用连续两帧像素/树比对判断"界面停了"，比固定 sleep 快 3~5 倍，也不会在慢的时候误判。

## 4. 中文输入为什么这次能直接打

`POST /wda/keys` 走的是"往第一响应者合成按键"。历史上很多工具（包括投屏类）在这里失败，原因是它们走剪贴板粘贴——而 iOS 会弹"允许粘贴"，多一次交互，还可能被系统拒。

实测：**WDA 的 keys 接口对 CJK 是通的**。`phone.cmd type 广州塔` 一次成功，无需拼音、无需剪贴板、无需弹窗。
失败时（极少数键盘为第三方输入法且未激活），退回 `field <文本>`：它用 accessibility 直接设 TextField 的 value。

## 5. 签名：这件事决定了"能用多久"

WDA 是装在你手机上的一个 App，必须有有效签名才能启动：

| 账号类型 | 有效期 | 说明 |
|---|---|---|
| 免费 Apple ID | **7 天** | 到期后 WDA 起不来，报 XCTest error 103 |
| 付费开发者（本机用这个，Team `YOUR_TEAM_ID`） | **364 天** | 到 2027-11-09；到期重新签一次即可 |

签名细节见 `02-从零部署.md` 第 4 节，尤其是"**必须剔除 `.dSYM`**"——不剔除 Sideloadly 直接报 `Failed to process app binary (-69)`。

## 6. 已知边界（别在这些地方浪费时间）

| 现象 | 原因 | 绕法 |
|---|---|---|
| 点不到屏幕最底部（Home 条那一条） | WDA 合成触摸够不到 home indicator 区域 | 用 `phone.cmd home` |
| 抖音/TikTok 信息流里 WDA 卡死 | 该页面永不响应 accessibility 请求，把 WDA "楔住" | 按 Home 释放；`phone.cmd home` 然后重新进 |
| 锁屏/睡眠时全挂 | 手机睡了，`ios apps --list` 也会空 | 侧键唤醒；服务会自动重连 |
| 视频流 App 截图黑屏 | 系统隐私保护（DRM 层） | 无法绕过，属正常 |
