import UIKit
import AVFoundation
import Network

// MARK: - 状态共享

final class MicState {
    static let shared = MicState()
    var statusText: String = "未开始"
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
    private var totalFrames = 0

    var onStatus: ((String) -> Void)?

    func start() {
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
            guard let self else { return }
            switch state {
            case .ready:
                self.onStatus?("电脑已连接，推流中 ✓")
                MicState.shared.streaming = true
                self.sendHeader(conn!)
            case .cancelled:
                self.onStatus?("电脑断开，等待重连…")
                MicState.shared.streaming = false
                lock.lock()
                if current === conn { current = nil }
                lock.unlock()
            case .failed:
                conn?.cancel()
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

// MARK: - 主界面 + 录音引擎

final class MicVC: UIViewController {
    private let server = StreamServer()
    private let engine = AVAudioEngine()
    private var running = false
    private var sessionActive = false

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
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

        button.setTitle("●  开始录音", for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 22)
        button.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 16
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        view.addSubview(button)

        hintLabel.text = "① 点开始，允许麦克风权限\n② 数据线连接电脑（或同一 WiFi）\n③ 电脑录音软件选 CABLE Output\n④ 可切到其他 App，声音持续推流\n⑤ 锁屏也不影响"
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
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.defaultToSpeaker, .allowBluetooth])
                    try session.setActive(true)
                    self.sessionActive = true
                    let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 48000, channels: 1, interleaved: true)!
                    self.engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
                        self?.handle(buffer)
                    }
                    self.engine.prepare()
                    try self.engine.start()
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

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.int16ChannelData else { return }
        let frames = Int(buffer.frameLength)
        let bytes = frames * 2
        let data = Data(bytes: ch[0], count: bytes)
        server.push(data)
    }

    private func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        server.stop()
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
        running = false
        button.setTitle("●  开始录音", for: .normal)
        button.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        statusLabel.text = "未开始"
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
