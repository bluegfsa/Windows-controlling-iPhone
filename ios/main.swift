import UIKit
import AVFoundation
import Network

// MARK: - 状态共享

final class MicState {
    static let shared = MicState()
    var streaming: Bool = false
}

// MARK: - 音频推流器（TCP 服务端，端口 17172）

final class StreamServer {
    static let port: UInt16 = 17172
    private var listener: NWListener?
    private let lock = NSLock()
    private var current: NWConnection?
    private var pending = Data()
    private var sending = false

    var onStatus: ((String) -> Void)?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            onStatus?("端口 17172 监听失败")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStatus?("等待电脑连接…")
            case .failed(let e): self?.onStatus?("监听失败: \(e)")
            default: break
            }
        }
        l.start(queue: DispatchQueue(label: "phonemic.server"))
        onStatus?("等待电脑连接…")
    }

    private func accept(_ conn: NWConnection) {
        lock.lock()
        let old = current
        current = conn
        pending = Data()
        sending = false
        lock.unlock()
        old?.cancel()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.onStatus?("电脑已连接，推流中 ✓")
                MicState.shared.streaming = true
                self.sendHeader(conn)
            case .cancelled:
                self.onStatus?("电脑断开，等待重连…")
                MicState.shared.streaming = false
                self.lock.lock()
                if self.current === conn { self.current = nil }
                self.lock.unlock()
            case .failed:
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: DispatchQueue(label: "phonemic.conn"))
    }

    // 头部: "PMIC" + version(u16) + sampleRate(u32le) + channels(u16) + bits(u16) + reserved(u32)
    private func sendHeader(_ conn: NWConnection) {
        var h = Data()
        h.append("PMIC".data(using: .ascii)!)
        var ver = UInt16(1).littleEndian; withUnsafeBytes(of: &ver) { h.append(contentsOf: $0) }
        var sr = UInt32(48000).littleEndian; withUnsafeBytes(of: &sr) { h.append(contentsOf: $0) }
        var ch = UInt16(1).littleEndian; withUnsafeBytes(of: &ch) { h.append(contentsOf: $0) }
        var bits = UInt16(16).littleEndian; withUnsafeBytes(of: &bits) { h.append(contentsOf: $0) }
        var rsv = UInt32(0).littleEndian; withUnsafeBytes(of: &rsv) { h.append(contentsOf: $0) }
        conn.send(content: h, completion: .contentProcessed { _ in })
    }

    func push(_ pcm: Data) {
        lock.lock()
        if current == nil { lock.unlock(); return }
        pending.append(pcm)
        if pending.count > 400_000 {  // 积压超过 ~4 秒，丢弃旧数据保实时
            pending.removeFirst(pending.count - 100_000)
        }
        if sending { lock.unlock(); return }
        sending = true
        lock.unlock()
        sendNext()
    }

    private func sendNext() {
        lock.lock()
        guard let conn = current, !pending.isEmpty else {
            sending = false
            lock.unlock()
            return
        }
        let chunk = pending
        pending = Data()
        lock.unlock()
        conn.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            self?.sendNext()
        })
    }

    func stop() {
        lock.lock()
        let c = current
        current = nil
        lock.unlock()
        c?.cancel()
        listener?.cancel()
        listener = nil
        MicState.shared.streaming = false
    }
}

// MARK: - 录音核心（抗打断：被电话/其他 App 抢走、切后台、锁屏、媒体服务重启都能自己回来）

final class AudioCore: NSObject {
    private var engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphReady = false
    private var tapInstalled = false
    private var running = false
    private var lastBufferAt = Date()
    private var lastMeterAt = Date(timeIntervalSince1970: 0)
    private var watchdog: Timer?
    private var silentBuffer: AVAudioPCMBuffer?

    var onPCM: ((Data) -> Void)?
    var onState: ((String) -> Void)?
    var onBytes: ((Int) -> Void)?
    private var totalBytes = 0

    override init() {
        super.init()
        let c = NotificationCenter.default
        c.addObserver(self, selector: #selector(handleInterruption(_:)),
                      name: AVAudioSession.interruptionNotification, object: nil)
        c.addObserver(self, selector: #selector(handleRouteChange(_:)),
                      name: AVAudioSession.routeChangeNotification, object: nil)
        c.addObserver(self, selector: #selector(handleMediaReset(_:)),
                      name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    // MARK: 生命周期

    func start() throws {
        running = true
        try startEngine()
        startWatchdog()
    }

    func stop() {
        running = false
        watchdog?.invalidate()
        watchdog = nil
        teardown()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 兜底：App 回到前台、或用户没点开始但会话掉了，都调这个
    func ensureRunning() {
        guard running else { return }
        if !engine.isRunning || Date().timeIntervalSince(lastBufferAt) > 3 {
            restart("前台唤醒")
        }
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true)

        buildGraph()

        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)   // 硬件真实格式（通常是 48k float32）
        if tapInstalled { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        lastBufferAt = Date()

        // 播放一条静音流，让音频会话保持"活跃"，切后台/锁屏不会被系统收走
        if let buf = silentBuffer {
            player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
            player.play()
        }
    }

    private func buildGraph() {
        if !graphReady {
            engine.attach(player)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            player.volume = 0
            let frames = AVAudioFrameCount(4410)
            if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) {
                buf.frameLength = frames   // 全 0 = 静音
                silentBuffer = buf
            }
            graphReady = true
        }
    }

    private func teardown() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
    }

    private func restart(_ why: String) {
        guard running else { return }
        onState?("自动恢复（\(why)）…")
        teardown()
        do {
            try startEngine()
            onState?("已恢复录音")
        } catch {
            onState?("恢复失败: \(error.localizedDescription)")
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            if !self.engine.isRunning || Date().timeIntervalSince(self.lastBufferAt) > 3 {
                self.restart(self.engine.isRunning ? "录音回调停止" : "引擎已停")
            }
        }
    }

    // MARK: 采音

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        if frames == 0 { return }
        lastBufferAt = Date()
        var data: Data
        if let i16 = buffer.int16ChannelData {
            data = Data(bytes: i16[0], count: frames * 2)
        } else if let f32 = buffer.floatChannelData {
            var arr = [Int16](repeating: 0, count: frames)
            let p = f32[0]
            for i in 0..<frames {
                let v = max(-1.0, min(1.0, p[i]))
                arr[i] = Int16(v * 32767.0)
            }
            data = arr.withUnsafeBufferPointer { Data(buffer: $0) }
        } else {
            return
        }
        totalBytes += data.count
        onPCM?(data)
        // UI 刷新节流，避免每秒 47 次跳主线程
        if Date().timeIntervalSince(lastMeterAt) > 0.5 {
            lastMeterAt = Date()
            onBytes?(totalBytes)
        }
    }

    // MARK: 系统事件

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onState?("被系统打断（来电/其他 App 占用麦克风）")
        case .ended:
            restart("打断结束")
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard running else { return }
        restart("音频通道变化")
    }

    @objc private func handleMediaReset(_ note: Notification) {
        guard running else { return }
        engine = AVAudioEngine()   // 媒体服务重置后旧引擎作废，必须重建
        graphReady = false
        tapInstalled = false
        restart("媒体服务重启")
    }
}

// MARK: - 主界面

final class MicVC: UIViewController {
    private let server = StreamServer()
    private let audio = AudioCore()
    private var running = false

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let meterLabel = UILabel()
    private let hintLabel = UILabel()
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1)

        titleLabel.text = "PhoneMic 手机麦克风"
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        statusLabel.text = "未开始"
        statusLabel.textColor = UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 17)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        meterLabel.text = "—"
        meterLabel.textColor = UIColor(white: 0.65, alpha: 1)
        meterLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        meterLabel.textAlignment = .center
        meterLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(meterLabel)

        button.setTitle("●  开始录音", for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 22)
        button.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 16
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        view.addSubview(button)

        hintLabel.text = "① 点开始，允许麦克风权限\n② 数据线连接电脑（或同一 WiFi）\n③ 电脑录音软件选 CABLE Output\n④ 可切到其他 App，声音持续推流\n⑤ 锁屏也不影响，被打断会自动恢复"
        hintLabel.textColor = UIColor(white: 0.8, alpha: 1)
        hintLabel.font = .systemFont(ofSize: 14)
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            meterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            meterLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 30),
            button.widthAnchor.constraint(equalToConstant: 240),
            button.heightAnchor.constraint(equalToConstant: 64),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
        ])

        server.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.statusLabel.text = text }
        }
        audio.onState = { [weak self] text in
            DispatchQueue.main.async { self?.meterLabel.text = text }
        }
        audio.onPCM = { [weak self] data in
            self?.server.push(data)
        }
        audio.onBytes = { [weak self] total in
            DispatchQueue.main.async {
                self?.meterLabel.text = String(format: "已发送 %.1f KB", Double(total) / 1024.0)
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(backToForeground),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func backToForeground() {
        audio.ensureRunning()
        if running { server.start() }
    }

    @objc private func toggle() {
        if running { stopMic() } else { startMic() }
    }

    private func startMic() {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if !granted {
                    self.statusLabel.text = "麦克风权限被拒绝，请到 设置 里开启"
                    return
                }
                do {
                    try self.audio.start()
                    self.server.start()
                    self.running = true
                    self.button.setTitle("■  停止录音", for: .normal)
                    self.button.backgroundColor = UIColor(red: 0.85, green: 0.30, blue: 0.30, alpha: 1)
                    self.statusLabel.text = "录音中，等待电脑连接…"
                } catch {
                    self.statusLabel.text = "启动失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopMic() {
        audio.stop()
        server.stop()
        running = false
        button.setTitle("●  开始录音", for: .normal)
        button.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        statusLabel.text = "未开始"
        meterLabel.text = "—"
    }
}

// MARK: - AppDelegate

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = MicVC()
        window?.makeKeyAndVisible()
        return true
    }
}

// MARK: - 入口

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
