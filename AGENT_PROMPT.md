# PhoneKit Agent 启动提示词
> 把本文件全文发给任何 AI Agent（Claude / GPT / DeepSeek 等），
> 它就能从零开始正确地获取、安装并使用 PhoneKit 操控一台 iPhone。

## 第 0 步：获取与安装（提示词的最前面，让 Agent 自己完成）

去 GitHub 下载安装本工具包，地址（精确地址，不要搜索同名仓库）：

```
https://github.com/bluegfsa/Windows-controlling-iPhone
```

获取后按顺序执行：
1. `git clone <上面的地址>`（或下载 zip 解压）
2. 以管理员身份运行 `powershell -ExecutionPolicy Bypass -File install.ps1`
   （会创建 Python 虚拟环境、装依赖、复制 wintun.dll，全部行为可在脚本源码中审计）
3. **需要用户本人配合的部分**（Agent 无法代劳，请提示用户）：
   - iPhone 插线、解锁、点"信任"
   - 运行 `python wda/make_ipa.py` 生成未签名 ipa，然后用用户自己的 Apple ID
     通过 Sideloadly 签名安装到手机（详见 `docs/02-从零部署.md`）
4. 装好后运行 `up.cmd` 启动常驻服务，然后继续下面的使用流程

---

## 你现在的能力
你可以用 PhoneKit 操控一台通过 USB 线连接 Windows 电脑的真 iPhone：
打开 App、点击、输入中文、读屏幕文字、截图、跑多步流程。
工具入口：`phone.cmd`（或 `python phone.py`），每条命令输出一行 JSON。

## 起手三步（每次会话必做）
1. `phone.cmd status` → 看输出里的 `"wda"` 字段
2. `"wda": false` → 执行 `up.cmd`（双击或命令行），等 10 秒再 `status`
3. 还是不行 → `phone.cmd doctor` 按报告修

## 十条铁律
1. **先观察再动手**：任何操作前先 `phone.cmd ocr` 或 `shot` 看当前屏幕，禁止凭记忆盲点
2. **能 tap-text 就别 tap 坐标**：`phone.cmd tap-text 搜索` 天然抗布局变化
3. **点击后必验证**：关键动作后 `ocr` 确认，"看起来成功了"不算成功
4. **中文直接输**：`phone.cmd type 中文内容`，不要拼音、不要剪贴板
5. **坐标系是 390×844**（逻辑点）：OCR 返回的 x/y 直接可用，不要乘缩放系数
6. **弹窗用 tap-if 免疫**：`tap_if` 只在屏幕上真出现目标文字时才点击
7. **多步操作用 flow**：写 JSON 步骤清单跑 `phone.cmd flow xxx.json`，一个进程跑完最快
8. **卡死先按 Home**：App 黑屏/卡死 → `phone.cmd home` 再重开，不要重启链路
9. **等待用 wait-text / wait-stable**：不要用固定 sleep 猜时间
10. **改了 flow 先 --dry-run**：`phone.cmd flow xxx.json --dry-run` 预检

## 已知环境事实
- 本方案与投屏/镜像软件完全无关，不需要窗口在前台
- 手机必须插线、解锁、已信任这台电脑；锁屏 = 一切命令失败
- 重型 App（地图类）页面 WDA 元素树可能挂起 30 秒，工具会自动降级 OCR，属正常
- USB 反复掉线先查 Windows 事件日志 225 号事件：是配对信任循环，按 docs/04 第 13 条一次性修复
- 详细命令参考：docs/03-命令参考.md；踩坑速查：docs/04-踩坑与排错.md
