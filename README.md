# PhoneKit — 用命令行操控一台真 iPhone（WDA 方案）

> 目标：让一个 Agent（或脚本、或你自己）用**一条命令**操作真机——打开 App、点击、输入中文、读屏幕文字、截图——并且**每一步都能截图核对**。
> 技术底座：go-ios（USB 通道）+ WebDriverAgent（iPhone 上的 HTTP 服务）+ SideTap（截图/OCR/会话复用引擎）。
> **跟 iPhoneMirror / 爱思助手 / 投屏软件完全无关**：不录屏、不模拟鼠标、不需要窗口在前台。

## 🤖 给 AI Agent 的一句话启用

**把 [`AGENT_PROMPT.md`](AGENT_PROMPT.md) 全文复制发给任意 AI Agent**（Claude / GPT / DeepSeek / WorkBuddy 等），它就会自己完成：下载本仓库 → 安装 → 启动服务 → 操控你的 iPhone。全程只需两处人工配合（插线点"信任"、Apple ID 签名 WDA）。

文档目录：[原理](docs/01-原理-为什么用WDA.md) · [从零部署](docs/02-从零部署.md) · [命令参考](docs/03-命令参考.md) · [踩坑与排错](docs/04-踩坑与排错.md) · [Agent 使用手册](docs/05-给DSH的使用说明.md) · [提速全过程](docs/06-提速全过程.md)

---

## 30 秒上手

```bat
:: 1. 一次性安装（建 venv、装依赖、检查环境）
powershell -ExecutionPolicy Bypass -File install.ps1

:: 2. 插上 iPhone，解锁，点"信任"；然后双击 up.cmd，把那个黑窗口最小化（别关）

:: 3. 开始用
phone.cmd status                                   :: {"service":true,"wda":true,...}
phone.cmd shot --path 1.png                        :: 截图
phone.cmd ocr --limit 20                           :: 屏幕上有哪些字、在哪个坐标
phone.cmd open 高德地图                             :: 中文名也行（查 data/apps_index.json）
phone.cmd open com.autonavi.amap                   :: bundle id 最稳
phone.cmd tap-text 搜索                             :: 点"搜索"
phone.cmd type 广州塔                               :: 直接输中文
phone.cmd flow examples\amap_navigate.json         :: 一整个流程，一个进程跑完
```

每条命令都输出**一行 JSON**，Agent 不需要猜。

---

## 为什么这条路对（对比过的三条路）

| 方案 | 找 App | 点内部按钮 | 每步截图 | 单步耗时 | 结论 |
|---|---|---|---|---|---|
| iPhoneMirror（投屏+反控） | 靠 Spotlight 碰运气 | 按截图手算坐标，偶发点错 | 有，但滞后 | 10~15 s | ❌ 太慢、不稳，中文输入还要过"允许粘贴"弹窗 |
| 快捷键 / 语音 | 可以 | 不行 | 不行 | — | ❌ 到不了 App 内部 |
| **WDA（本包）** | **按 bundle id，0.12~1.4 s** | **accessibility 树真实元素，0.4~0.7 s 命中** | **`/screenshot` 实时帧，0.16~0.43 s** | **1~3 s/步** | ✅ 唯一同时满足"快 + 准 + 可截图" |

关键差别：WDA 拿到的是**结构化元素树**（文字、类型、坐标、可点性），不是"一张图 + 猜坐标"。所以文字判状态、按名字点按钮、等待界面稳定，都是确定性的。

---

## 包里有什么

```
PhoneKit/
├─ phone.cmd / phone.py       ← 唯一入口（11 个子命令 + flow 批量模式）
├─ kitpatch.py                ← Windows 兼容补丁（netstat 返回 None、GBK 解码）
├─ up.cmd / down.cmd          ← 起/停常驻服务（把链路预热，命令才能 1 秒级）
├─ service.py                 ← 常驻服务：隧道 + WDA + 端口转发不退出
├─ install.ps1                ← 一键安装（venv + 依赖 + wintun + 体检）
├─ bin/ios.exe                ← go-ios 1.3.2，已内置，不用装 Node
├─ bin/wintun.dll             ← iOS 17+ 隧道依赖（需复制到 System32，install.ps1 会做）
├─ wda/make_ipa.py            ← 一键从 Appium WDA release 生成可签名 ipa（仓库不含 ipa，见 NOTICE.md）
├─ data/apps_index.json       ← 61 个常用 App 的中文名 ↔ bundle id 示例（可按自己手机重建）
├─ src/phone_harness/         ← 引擎源码（基于 SideTap，MIT）：截图/OCR/树/tap/输入/会话复用
├─ examples/*.json            ← 可直接跑的流程（高德导航 / 微信发消息 / 看当前状态）
├─ start.vbs                  ← 可选：无窗口启动服务（up.cmd 是推荐方式）
├─ artifacts/                 ← 运行时自动创建：截图、服务日志都落在这里
└─ docs/
   ├─ 01-原理-为什么用WDA.md
   ├─ 02-从零部署.md           ← 换一台电脑、换一台 iPhone 的全流程
   ├─ 03-命令参考.md
   ├─ 04-踩坑与排错.md         ← 我们真踩过的 20 个坑，逐条给解法
   ├─ 05-给DSH的使用说明.md    ← 交给 Agent 的那份（决策树 + 铁律 + 配方）
   └─ 06-提速全过程.md         ← 从 15 秒/步 到 1~3 秒/步 改了什么
```

---

## 三条铁律（先记住，再看细节）

1. **先 `ocr`，再点。** 坐标不要跨屏缓存——同一页面上下滑动 6 px 就会点错。`iphone` 的逻辑分辨率是 390×844，OCR 给的 x/y 就是可点的逻辑点。
2. **能 `tap-text` 就别 `tap x y`。** 按文字/标签点，天然抗布局变化。
3. **一步一确认。** 关键步骤后 `phone.cmd ocr` 或 `shot --path x.png`，用文字判断状态，不要把"看起来成功了"当成功。

---

## 现在就能跑的两个真场景

**① 高德导航到某地、不走高速**（本包已验证，全程约 15 秒 / 6 步）

```bat
phone.cmd flow examples\amap_navigate.json
```

**② 读屏判断当前在哪个 App**

```bat
phone.cmd app
phone.cmd ocr --grep 订单
```

更多配方见 `docs/05-给DSH的使用说明.md`。
