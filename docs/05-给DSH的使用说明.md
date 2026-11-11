# 05 · 给 DSH 的使用说明（Agent 操作手册）

> 这一份是**给模型看的**。人的说明书是 README + 03。可以直接把本文件（或"零、系统提示"那一段）放进 DSH 的上下文。

---

## 零、系统提示（可直接粘贴）

```
你可以用 phone.cmd 操控一台真实 iPhone。它输出 JSON，每次调用是一个独立进程。工作目录：PhoneKit 解压目录（phone.cmd 在根目录）。

铁律：
1. 动手前先 `phone.cmd status`；wda 不为 true 就先 `phone.cmd up`（最长等 150 秒，别放弃）。USB 掉线会自动修复（最多等 2 分钟），报"not visible over USB"才是真掉线，让人插线/解锁/信任。
2. 每到一个新界面，先 `phone.cmd ocr --grep <关键词>` 或 `--limit 25` 看清楚有什么，再决定点哪里。
3. 优先 `tap-text <文字>`，其次 `tap <x> <y>`；用坐标前必须是本轮 ocr 刚拿到的坐标，不要复用上一屏的。
4. 点击后要验证：`ocr`/`find`/`shot` 任一方式确认状态变化，不要假定成功。
5. 需要看画面时才截图（`shot --path x.png`）；只判断"有没有某个字/在哪个页"就用 `ocr --grep`，省 token。
6. 一个流程有 3 步以上且中途不需要判断，写成 flow json 一次跑完（`phone.cmd flow f.json`）；能套用 examples/ 里的模板就套（改顶层字段即可模板替换 {{var}}）。
7. 输中文直接 `phone.cmd type 广州塔`，不要拼音、不要剪贴板。
8. 不要点屏幕最底部（Home 条区域），要回桌面用 `phone.cmd home`。
9. 卡住/超时先 `phone.cmd home`，再 `phone.cmd status`；还不行跑 `phone.cmd doctor`，它的 hint 会告诉你原因。
10. 可能出现、也可能不出现的弹窗（权限框、"跳过"、更新提示）用 `phone.cmd tap-if 不允许`——点了就过，没弹窗自动跳过，绝不用 tap-text 硬点弹窗按钮。
11. 全部坐标基于 screen.width/height（本机 iPhone 13 = 390×844 逻辑点）；换机型先重新校准。
```

---

## 一、开场自检（每个任务开头，只做一次）

```bat
phone.cmd status
```

```jsonc
{"service": true, "wda": true, "app": "com.apple.springboard",
 "screen": {"width": 390, "height": 844}, "ok": true, "ms": 812}
```

判断：

| 情况 | 动作 |
|---|---|
| `wda: true` | 直接干活 |
| `wda: false` | `phone.cmd up`（可能 20~150 s，正常，不要打断） |
| `up` 也失败 | `phone.cmd doctor`，读第一个 FAIL 的 `fix`；`error` 里若是"not on USB"，让人插线/解锁/信任 |

**记下 `screen.width/height`**：所有坐标都基于它（iPhone 13 = 390×844）。

---

## 二、核心循环（六步法）

```
① 定位     app          → 我现在在哪个 App？
② 观察     ocr --limit 25 → 屏上有什么字、什么按钮、什么坐标
③ 决策     对照目标，选最稳的一步（优先 tap-text）
④ 执行     tap-text / tap / type / open
⑤ 验证     ocr --grep 期望文字（或 wait-text）
⑥ 记录     需要留证就 shot --path 步骤名.png
```

关键：**①→②是一组，④→⑤是一组**。不要 ④④④⑤，那是赌博。

---

## 三、决策树：怎么"点"最稳

```
目标元素能在 ocr 里看到文字/标签？
├─ 能 → tap-text "<那串文字>"        ← 90% 的情况走这条
│        同名多个？→ 先 ocr --grep 看坐标，再用 --index
└─ 不能（纯图标、图片按钮、Canvas 绘制）
   ├─ 有 accessibility 标签 → tap-text "<标签>"（Image 类型也有 text 字段）
   └─ 完全没有 → ocr 拿到邻近文字做参照，算相对偏移后 tap x y
                （只在这一屏用，换屏必须重算）
```

**永远不要**：跨屏复用坐标、按比例换算 PNG 像素、用 `sleep` 代替 `wait-text`。

---

## 四、配方（已验证）

### 4.1 高德地图：导航到某地，不走高速

```bat
phone.cmd open com.autonavi.amap
```
```jsonc
// 然后看首页元素，搜索框通常在顶部：
// {"text":"搜索框，输入文字查找地点、公交、地铁","x":132,"y":466,"type":"StaticText"}
phone.cmd tap 132 466
phone.cmd type 广州塔
phone.cmd ocr --grep 路线          // 搜索结果每行右侧都有"路线"按钮
phone.cmd tap-text 路线 --index 0  // 第一条结果的路线
```

进入路线页后：
```jsonc
// {"text":"起点:我的位置"}, {"text":"终点:广州塔"},
// {"text":"偏好","x":53,"y":558}, {"text":"开始导航","x":278,"y":792}
phone.cmd tap-text 偏好
phone.cmd tap-text 不走高速         // 选中后建议加一张截图确认
phone.cmd shot --path 偏好确认.png
phone.cmd tap-text 开始导航
phone.cmd ocr --limit 12           // 期望出现"退出导航按钮"、剩余时间/里程
```

成品：`examples/amap_navigate.json`——**已实测 22 步全绿、65 秒端到端**（含冷启动开屏自愈）。改目的地只需改文件顶层的 `"dest"` 字段，flow 支持 `{{dest}}` 模板替换：
```bat
phone.cmd flow examples\amap_navigate.json
```
已内置的容错，不用你操心：开屏卡黑屏自动按 Home 重开（retry 块）；「开始导航」后的麦克风权限弹窗自动点"不允许"（tap_if）；路线规划页 WDA 树挂起时自动降级 OCR。

> 注意：搜索结果第一条不一定是你想去的同名地点。**先 `ocr --grep` 看清每行的小字**（区/镇/门牌），确认后再点。

### 4.2 微信：给某人发一条消息

```bat
phone.cmd open com.tencent.xin
phone.cmd ocr --grep 搜索
phone.cmd tap-text 搜索
phone.cmd type 阿伟
phone.cmd ocr --grep 阿伟          // 确认是"联系人"那一行，不是聊天记录
phone.cmd tap-text 阿伟 --index 0
phone.cmd tap 195 800              // 底部输入框（先用 ocr 确认）
phone.cmd type 晚上八点到
phone.cmd tap-text 发送
phone.cmd ocr --grep 晚上八点到     // 验证气泡真的发出去了
```

> 发送是**不可撤销动作**。规则：发之前 `shot --path 发送前.png` 留证；发之后必须验证气泡出现在会话里。

### 4.3 只想知道"现在是什么状态"，不截图

```bat
phone.cmd app                                   // 前台 bundle id
phone.cmd ocr --grep 订单 --limit 10            // 有没有"订单"
```
这是最省 token 的方式：**不要**动不动截图再让模型看。

### 4.4 打开刚下的 TestFlight 测试包

```bat
phone.cmd open com.apple.TestFlight
phone.cmd ocr --grep 打开
phone.cmd tap-text 打开
phone.cmd wait-text 开始使用 --timeout 15
phone.cmd ocr --limit 15
```
个别测试包首次启动会弹"是否允许通知"，`ocr --grep 允许` 后 `tap-text 允许`。

### 4.5 等一个慢动作（下载、加载、跳转）

```bat
phone.cmd wait-text 下载完成 --timeout 60
```
不要 `sleep 30`。`wait-text` 命中就返回，平均省一半时间。

---

## 五、什么时候用 `flow`

- 步骤 ≥ 3 且**中间不需要模型判断**
- 需要精确时序（点击后必须立刻输入，避免焦点被抢）
- 同一个流程要重复跑

写法（坐标要先用 ocr 校准过一次再写进去）：

```jsonc
{
  "name": "open-settings-wifi",
  "steps": [
    {"cmd": "open", "args": {"app": "com.apple.Preferences"}},
    {"cmd": "tap_text", "args": {"text": "无线局域网"}},
    {"cmd": "wait_stable", "args": {"timeout": 5}},
    {"cmd": "shot", "args": {"path": "wifi.png"}},
    {"cmd": "ocr", "args": {"grep": "Wi-Fi", "limit": 10}}
  ]
}
```

一旦中途需要"看看再决定"，就**别用 flow**，退回逐步调用。

---

## 六、错误处理表

| 返回 | 含义 | 下一步 |
|---|---|---|
| `{"ok":false,"error":"WDA never answered"}` | 链路没起来 | `doctor` → 看第一个 FAIL |
| `{"ok":false,"error":"tap_text(...) failed"}` + `hint: N candidate(s)` | 没找到/找到多个 | `ocr --grep <关键词>` 看真实文字，注意全角/半角、书名号、空格 |
| `find` 返回 `ok:false` | 断言不成立 | 说明还在上一页，`ocr --limit 30` 看看现在在哪 |
| 命令全部超时（连 `app` 都慢） | WDA 被当前 App 楔住 | `phone.cmd home` → `status` |
| `doctor` 报 "not on USB" | 线掉了/没信任/手机睡了 | 让人插线、解锁、点信任 |
| 反复掉线，几分钟后又掉 | **配对信任失效循环**（系统日志 225，AppleMobileDeviceService 主动弹出） | 让人做一次性修复：拔线 → 手机上「设置→通用→传输或还原 iPhone→还原→还原位置与隐私」→ 重插 → 点信任。**不要**反复重装驱动，见 `04` 第 13 条 |
| `doctor` 报 WDA 未安装 | 签名失效（付费 364 天 / 免费 7 天） | 重新侧载，见 `02-从零部署.md` 第 4 节 |

---

## 七、反面清单（这些做法一定吃亏）

| ❌ 不要 | ✅ 改成 |
|---|---|
| 用上一屏的坐标 | 每次点击前重新 `ocr` |
| `sleep 3` 等加载 | `wait-text` / `wait-stable` |
| 每步都截图喂模型 | `ocr --grep` 先判断，必要时才 `shot` |
| 用 `open_app("设置")` 这类中文名 | `com.apple.Preferences` 等 bundle id（或先 `apps` 建表） |
| 点底部 Home 条 | `phone.cmd home` |
| 一个任务拆成 20 次独立调用 | 无判断的连续步骤合成 `flow` |
| 假定点击成功 | 每步之后用文字验证 |
| 在抖音/TikTok 信息流里硬试 | 先 `home`，或改用搜索入口进 |
