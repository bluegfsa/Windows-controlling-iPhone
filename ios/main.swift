import UIKit
import AVFoundation
import VideoToolbox
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
    private var lastRestartAt = Date(timeIntervalSince1970: 0)
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
        do {
            try startEngine()
        } catch {
            running = false
            throw error
        }
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
        // 去抖：重新激活会话本身会再发一次 routeChange，不去抖会自己触发自己
        if Date().timeIntervalSince(lastRestartAt) < 3.0 { return }
        lastRestartAt = Date()
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

// MARK: - 视频推流器（TCP 服务端，端口 17174）

enum NetInfo {
    /// WiFi（en0）上的 IPv4。取不到说明手机没连 WiFi，只有蜂窝网。
    static func wifiIP() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var found: String?
        var p = first
        while true {
            let a = p.pointee
            if let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               String(cString: a.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0,
                               NI_NUMERICHOST) == 0 {
                    found = String(cString: host)
                }
            }
            guard let n = a.ifa_next else { break }
            p = n
        }
        return found
    }
}

/// 每 2 秒朝局域网广播一次「我在这」，电脑端监听 17175 直接拿到 IP 与端口，
/// 不用再猜地址、也不用扫整个网段。
final class Beacon {
    private var fd: Int32 = -1
    private var timer: Timer?

    func start() {
        guard fd < 0 else { return }
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on,
                   socklen_t(MemoryLayout<Int32>.size))
        send()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.send()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func send() {
        guard fd >= 0, let ip = NetInfo.wifiIP() else { return }
        let msg = "PHONEMIC-HERE \(ip)\n"
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(17175).bigEndian
        addr.sin_addr.s_addr = inet_addr("255.255.255.255")
        msg.withCString { cstr in
            _ = withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    sendto(fd, cstr, strlen(cstr), 0, sap,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

final class VideoServer {
    static let port: UInt16 = 17174
    private var listener: NWListener?
    private let lock = NSLock()
    private var current: NWConnection?
    private var queue: [Data] = []
    private var sending = false
    private var header = Data()

    var onStatus: ((String) -> Void)?
    var onNeedKeyframe: (() -> Void)?

    private static func makeHeader(width: Int32, height: Int32, fps: Int32) -> Data {
        var d = Data()
        d.append("PMV1".data(using: .ascii)!)
        var ver = UInt16(1).littleEndian
        withUnsafeBytes(of: &ver) { d.append(contentsOf: $0) }
        var w = UInt32(width).littleEndian
        withUnsafeBytes(of: &w) { d.append(contentsOf: $0) }
        var h = UInt32(height).littleEndian
        withUnsafeBytes(of: &h) { d.append(contentsOf: $0) }
        var f = UInt16(fps).littleEndian
        withUnsafeBytes(of: &f) { d.append(contentsOf: $0) }
        var rsv = UInt16(0).littleEndian
        withUnsafeBytes(of: &rsv) { d.append(contentsOf: $0) }
        return d  // 4 + 2 + 4 + 4 + 2 + 2 = 18 字节
    }

    var connected: Bool {
        lock.lock()
        let has = current != nil
        lock.unlock()
        return has
    }

    func start(width: Int32, height: Int32, fps: Int32) {
        guard listener == nil else { return }
        header = VideoServer.makeHeader(width: width, height: height, fps: fps)
        let params = NWParameters.tcp
        guard let l = try? NWListener(using: params,
                                      on: NWEndpoint.Port(rawValue: Self.port)!) else {
            onStatus?("视频端口 17174 监听失败")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                self?.onStatus?("视频监听失败: \(e)")
            }
        }
        l.start(queue: DispatchQueue(label: "phonemic.video.server"))
        onStatus?("等待电脑连接 · \(NetInfo.wifiIP() ?? "无 WiFi"):17174")
    }

    private func accept(_ conn: NWConnection) {
        lock.lock()
        let old = current
        current = conn
        queue.removeAll()
        sending = false
        lock.unlock()
        old?.cancel()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                conn.send(content: self.header, completion: .contentProcessed { _ in })
                self.onStatus?("视频：电脑已连接 ✓")
                self.onNeedKeyframe?()
            case .cancelled:
                self.onStatus?("视频：电脑断开，等待重连…")
                self.lock.lock()
                if self.current === conn { self.current = nil }
                self.lock.unlock()
            case .failed:
                self.lock.lock()
                if self.current === conn { self.current = nil }
                self.lock.unlock()
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "phonemic.video.conn"))
    }

    func push(_ frame: Data, isKey: Bool) {
        var packet = Data(capacity: frame.count + 5)
        var len = UInt32(frame.count).littleEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(isKey ? 1 : 0)
        packet.append(frame)

        lock.lock()
        guard current != nil else { lock.unlock(); return }
        queue.append(packet)
        var needKey = false
        if queue.count > 6 {
            // 积压说明网络跟不上：丢掉旧帧，并从关键帧开始重发，保证画面实时
            queue.removeFirst(queue.count - 6)
            if let k = queue.firstIndex(where: { $0[4] == 1 }) {
                if k > 0 { queue.removeFirst(k) }
            } else {
                queue.removeAll()
                needKey = true
            }
        }
        let alreadySending = sending
        if !alreadySending { sending = true }
        lock.unlock()
        if needKey { onNeedKeyframe?() }
        if !alreadySending { sendNext() }
    }

    private func sendNext() {
        lock.lock()
        guard let conn = current, !queue.isEmpty else {
            sending = false
            lock.unlock()
            return
        }
        let chunk = queue.removeFirst()
        lock.unlock()
        conn.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            self?.sendNext()
        })
    }

    func stop() {
        lock.lock()
        let c = current
        current = nil
        queue.removeAll()
        sending = false
        lock.unlock()
        c?.cancel()
        listener?.cancel()
        listener = nil
    }
}

// MARK: - 摄像头采集 + VideoToolbox 硬编（输出 Annex-B H.264）

final class CameraCore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var encoder: VTCompressionSession?
    private var encW: Int32 = 0
    private var encH: Int32 = 0
    private var forceKey = true
    private var running = false
    private var frames = 0
    private var bytes = 0
    private var lastStat = Date()
    private var position: AVCaptureDevice.Position = .front
    /// 采集方向：默认竖屏。传感器原始画面永远是横向，必须靠它转正，否则电脑端看到横图
    private(set) var orientation: AVCaptureVideoOrientation = .portrait
    private var lastFrameAt = Date()
    private var watchdog: Timer?

    var onFrame: ((Data, Bool) -> Void)?
    var onState: ((String) -> Void)?
    var onStats: ((Double, Double) -> Void)?

    var isRunning: Bool { running }
    var isSessionRunning: Bool { session.isRunning }
    var isFront: Bool { position == .front }
    private(set) var currentDevice: AVCaptureDevice?

    struct CameraInfo {
        let device: AVCaptureDevice
        let title: String
    }

    /// 列出手机上所有可用摄像头（前置 / 后置主摄 / 超广角 / 长焦）
    static func availableCameras() -> [CameraInfo] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
        ]
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                  mediaType: .video,
                                                  position: .unspecified)
        var infos: [CameraInfo] = []
        for dev in ds.devices {
            if infos.contains(where: { $0.device.uniqueID == dev.uniqueID }) { continue }
            infos.append(CameraInfo(device: dev, title: title(for: dev)))
        }
        func rank(_ dev: AVCaptureDevice) -> Int {
            if dev.position == .front { return dev.deviceType == .builtInWideAngleCamera ? 0 : 1 }
            switch dev.deviceType {
            case .builtInWideAngleCamera: return 2
            case .builtInUltraWideCamera: return 3
            case .builtInTelephotoCamera: return 4
            default: return 5
            }
        }
        return infos.sorted { rank($0.device) < rank($1.device) }
    }

    static func title(for dev: AVCaptureDevice) -> String {
        let p = (dev.position == .front) ? "前置" : "后置"
        switch dev.deviceType {
        case .builtInUltraWideCamera: return p + "超广角"
        case .builtInTelephotoCamera: return p + "长焦"
        default: return p + "主摄"
        }
    }

    func start(position p: AVCaptureDevice.Position) throws {
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                for: .video, position: p) else {
            throw NSError(domain: "PhoneMic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用摄像头"])
        }
        try select(dev)
    }

    /// 切到指定摄像头：停流 → 销毁编码器 → 重建 → 强制关键帧，
    /// 保证电脑端拿到新的 SPS/PPS+IDR，不会黑屏等下一个 GOP。
    func select(_ device: AVCaptureDevice) throws {
        let wasRunning = running
        running = false
        if wasRunning { session.stopRunning() }
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
        encW = 0
        encH = 0
        forceKey = true
        position = device.position   // 必须先更新，configure 里要按新摄像头决定是否镜像
        try configure(device: device)
        currentDevice = device
        frames = 0
        bytes = 0
        lastStat = Date()
        running = true
        lastFrameAt = Date()
        startWatchdog()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        running = false
        watchdog?.invalidate()
        watchdog = nil
        session.stopRunning()
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
        encW = 0
        encH = 0
    }

    /// 系统中断（切后台/被抢占）后重新拉起当前摄像头
    func restartCurrent() {
        guard let dev = currentDevice else { return }
        try? select(dev)
    }

    /// 帧看门狗：推流中超过 4 秒没有新帧，说明会话被系统挂住了（切后台、被抢占），
    /// 自动重建一次。后台时定时器不跑，回到前台第一次触发就会救回来。
    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkFrames()
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func checkFrames() {
        guard running, session.isRunning else { return }
        if Date().timeIntervalSince(lastFrameAt) > 4.0 {
            onState?("相机无画面，自动重连…")
            restartCurrent()
        }
    }

    func requestKeyframe() {
        forceKey = true
    }

    /// 跟随手机朝向调整输出方向。输出像素会被硬件直接转正，
    /// 分辨率随之从 1280x720 变成 720x1280，编码器会自动重建并补关键帧。
    func applyOrientation(_ o: AVCaptureVideoOrientation) {
        guard o != orientation else { return }
        orientation = o
        session.beginConfiguration()
        if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = o
        }
        session.commitConfiguration()

        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
        encW = 0
        encH = 0
        forceKey = true
    }

    private func configure(device dev: AVCaptureDevice) throws {
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }
        for i in session.inputs { session.removeInput(i) }

        let input = try AVCaptureDeviceInput(device: dev)
        if session.canAddInput(input) { session.addInput(input) }

        if !session.outputs.contains(output) {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "phonemic.camera"))
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        if let conn = output.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = orientation
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                // 与手机上的预览层保持一致：前摄镜像（自拍观感），后摄不镜像
                conn.isVideoMirrored = (dev.position == .front)
            }
        }
        try? dev.lockForConfiguration()
        dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        dev.unlockForConfiguration()
        session.commitConfiguration()
    }

    func captureOutput(_ captureOutput: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameAt = Date()
        let w = Int32(CVPixelBufferGetWidth(pb))
        let h = Int32(CVPixelBufferGetHeight(pb))
        guard let enc = ensureEncoder(width: w, height: h) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var props: [String: Any] = [:]
        if forceKey {
            props[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true
            forceKey = false
        }
        let frameProps: CFDictionary? = props.isEmpty ? nil : (props as CFDictionary)
        VTCompressionSessionEncodeFrame(enc, imageBuffer: pb,
                                        presentationTimeStamp: pts,
                                        duration: .invalid,
                                        frameProperties: frameProps,
                                        infoFlagsOut: nil) { [weak self] status, _, sbuf in
            guard let self, status == noErr, let sbuf else { return }
            let notSync = CMGetAttachment(sbuf, key: kCMSampleAttachmentKey_NotSync,
                                          attachmentModeOut: nil)
            let isKey = (notSync == nil)
            guard let data = CameraCore.annexB(sbuf, withParameterSets: isKey) else { return }
            self.bytes += data.count
            self.frames += 1
            self.reportIfNeeded()
            self.onFrame?(data, isKey)
        }
    }

    private func reportIfNeeded() {
        let now = Date()
        let dt = now.timeIntervalSince(lastStat)
        guard dt >= 1.0 else { return }
        let fps = Double(frames) / dt
        let kbps = Double(bytes) * 8.0 / 1000.0 / dt
        frames = 0
        bytes = 0
        lastStat = now
        onStats?(fps, kbps)
    }

    private func ensureEncoder(width: Int32, height: Int32) -> VTCompressionSession? {
        if let e = encoder, encW == width, encH == height { return e }
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil

        var session: VTCompressionSession?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        let st = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                            width: width,
                                            height: height,
                                            codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil,
                                            imageBufferAttributes: attrs as CFDictionary,
                                            compressedDataAllocator: nil,
                                            outputCallback: nil,
                                            refcon: nil,
                                            compressionSessionOut: &session)
        guard st == noErr, let s = session else {
            onState?("编码器创建失败 (\(st))")
            return nil
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: 4_000_000))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: 60))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(s)
        encoder = s
        encW = width
        encH = height
        forceKey = true
        return s
    }

    /// AVCC（4 字节长度前缀）转 Annex-B（00 00 00 01 起始码）
    private static func annexB(_ sb: CMSampleBuffer, withParameterSets: Bool) -> Data? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var out = Data()

        if withParameterSets {
            var count = 0
            var nalLen: Int32 = 4
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
            if st == noErr, count > 0 {
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    let s2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if s2 == noErr, let p = ptr, size > 0 {
                        out.append(contentsOf: [0, 0, 0, 1] as [UInt8])
                        out.append(p, count: size)
                    }
                }
            }
        }

        var lenAtOffset = 0
        var total = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0,
                                          lengthAtOffsetOut: &lenAtOffset,
                                          totalLengthOut: &total,
                                          dataPointerOut: &dataPtr) == noErr,
              let base = dataPtr else { return out.isEmpty ? nil : out }

        var headerLen = 4
        if let fmt2 = CMSampleBufferGetFormatDescription(sb) {
            var n: Int32 = 4
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt2, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: &n) == noErr, n > 0 {
                headerLen = Int(n)
            }
        }

        var offset = 0
        while offset + headerLen <= total {
            var nalSize = 0
            for k in 0..<headerLen {
                nalSize = (nalSize << 8) | Int(UInt8(bitPattern: base[offset + k]))
            }
            offset += headerLen
            if nalSize <= 0 || offset + nalSize > total { break }
            out.append(contentsOf: [0, 0, 0, 1] as [UInt8])
            let p = UnsafeRawPointer(base + offset).assumingMemoryBound(to: UInt8.self)
            out.append(contentsOf: UnsafeBufferPointer(start: p, count: nalSize))
            offset += nalSize
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - 主界面

final class MicVC: UIViewController {
    private let server = StreamServer()
    private let video = VideoServer()
    private let beacon = Beacon()
    private let audio = AudioCore()
    private let camera = CameraCore()
    private var running = false

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let meterLabel = UILabel()
    private let hintLabel = UILabel()
    private let statsLabel = UILabel()
    private let previewView = UIView()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let button = UIButton(type: .system)
    private let cameraBar = UIScrollView()
    private let cameraStack = UIStackView()
    private var cameraButtons: [UIButton] = []
    private var cameras: [CameraCore.CameraInfo] = []
    private var chosen: AVCaptureDevice?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1)

        previewView.backgroundColor = UIColor.black
        previewView.layer.cornerRadius = 14
        previewView.clipsToBounds = true
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        let pl = AVCaptureVideoPreviewLayer(session: camera.session)
        pl.videoGravity = .resizeAspectFill
        previewView.layer.addSublayer(pl)
        previewLayer = pl

        titleLabel.text = "PhoneMic 手机相机"
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

        button.setTitle("●  开始推流", for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 22)
        button.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 16
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        view.addSubview(button)

        cameraBar.showsHorizontalScrollIndicator = false
        cameraBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cameraBar)

        cameraStack.axis = .horizontal
        cameraStack.spacing = 8
        cameraStack.alignment = .fill
        cameraStack.translatesAutoresizingMaskIntoConstraints = false
        cameraBar.addSubview(cameraStack)

        statsLabel.text = "—"
        statsLabel.textColor = UIColor(white: 0.65, alpha: 1)
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statsLabel.textAlignment = .center
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)

        hintLabel.text = "① 点开始，允许相机与麦克风权限\n② 手机横放效果最好（16:9）\n③ 下方按钮可随时切换任意摄像头\n④ 电脑运行 phonemic_video.py 看画面\n⑤ 后台相机会被系统暂停，回前台自动恢复"
        hintLabel.textColor = UIColor(white: 0.8, alpha: 1)
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),

            previewView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            previewView.heightAnchor.constraint(equalTo: previewView.widthAnchor, multiplier: 9.0 / 16.0),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            meterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            meterLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),

            statsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statsLabel.topAnchor.constraint(equalTo: meterLabel.bottomAnchor, constant: 4),

            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 20),
            button.widthAnchor.constraint(equalToConstant: 240),
            button.heightAnchor.constraint(equalToConstant: 60),

            cameraBar.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 12),
            cameraBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cameraBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cameraBar.heightAnchor.constraint(equalToConstant: 40),

            cameraStack.leadingAnchor.constraint(equalTo: cameraBar.leadingAnchor),
            cameraStack.trailingAnchor.constraint(equalTo: cameraBar.trailingAnchor),
            cameraStack.topAnchor.constraint(equalTo: cameraBar.topAnchor),
            cameraStack.bottomAnchor.constraint(equalTo: cameraBar.bottomAnchor),

            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
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

        video.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.statusLabel.text = text }
        }
        video.onNeedKeyframe = { [weak self] in
            self?.camera.requestKeyframe()
        }
        camera.onFrame = { [weak self] data, isKey in
            self?.video.push(data, isKey: isKey)
        }
        camera.onStats = { [weak self] fps, kbps in
            DispatchQueue.main.async {
                self?.statsLabel.text = String(format: "视频 %.0f fps · %.0f kbps", fps, kbps)
            }
        }
        camera.onState = { [weak self] text in
            DispatchQueue.main.async { self?.statsLabel.text = text }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(backToForeground),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification, object: camera.session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification, object: camera.session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: camera.session)

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceRotated),
            name: UIDevice.orientationDidChangeNotification, object: nil)

        reloadCameras()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
    }

    /// 手机一转，采集/预览/推流一起转正
    @objc private func deviceRotated() {
        guard let o = MicVC.videoOrientation(from: UIDevice.current.orientation) else { return }
        camera.applyOrientation(o)
        previewLayer?.connection?.videoOrientation = o
        if camera.isRunning { camera.requestKeyframe() }
    }

    private static func videoOrientation(from o: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
        switch o {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil
        }
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
        var text = "相机被系统中断"
        if let r = reason {
            switch r {
            case .videoDeviceNotAvailableInBackground: text += "（切到了后台）"
            case .videoDeviceInUseByAnotherClient: text += "（相机被其他 App 占用）"
            case .audioDeviceInUseByAnotherClient: text += "（麦克风被其他 App 占用）"
            default: text += ""
            }
        }
        statusLabel.text = text + "，回到前台自动恢复"
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        guard running else { return }
        camera.restartCurrent()
        camera.requestKeyframe()
        statusLabel.text = "相机已恢复"
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        guard running else { return }
        // 运行期错误（切后台回来、设备被抢占等）直接重建会话
        camera.restartCurrent()
        syncPreviewMirroring()
        statusLabel.text = "相机已自动重连"
    }

    /// 把手机上所有摄像头列成一排按钮，点哪个切哪个
    private func reloadCameras() {
        cameras = CameraCore.availableCameras()
        for b in cameraButtons { b.removeFromSuperview() }
        cameraButtons.removeAll()

        for (i, info) in cameras.enumerated() {
            let b = UIButton(type: .system)
            b.setTitle(info.title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            b.layer.cornerRadius = 10
            b.tag = i
            b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
            b.addTarget(self, action: #selector(pickCamera(_:)), for: .touchUpInside)
            cameraStack.addArrangedSubview(b)
            cameraButtons.append(b)
        }
        if chosen == nil { chosen = cameras.first?.device }
        highlightCamera()
    }

    private func highlightCamera() {
        for (i, b) in cameraButtons.enumerated() {
            let on = (cameras[i].device.uniqueID == chosen?.uniqueID)
            b.backgroundColor = on
                ? UIColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1)
                : UIColor(white: 1, alpha: 0.08)
            b.setTitleColor(on ? .white : UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1),
                            for: .normal)
        }
    }

    private func syncPreviewMirroring() {
        guard let conn = previewLayer?.connection else { return }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = camera.isFront
        }
    }

    @objc private func pickCamera(_ sender: UIButton) {
        guard sender.tag < cameras.count else { return }
        let info = cameras[sender.tag]
        chosen = info.device
        highlightCamera()
        guard camera.isRunning else {
            statusLabel.text = "已选「\(info.title)」，点开始推流生效"
            return
        }
        do {
            try camera.select(info.device)
            syncPreviewMirroring()
            statusLabel.text = "已切到「\(info.title)」"
        } catch {
            statusLabel.text = "切换失败: \(error.localizedDescription)"
        }
    }

    @objc private func backToForeground() {
        audio.ensureRunning()
        if running {
            server.start()
            // 回前台一律重建相机会话：被系统中断后 isRunning 仍可能是 true，
            // 只靠它判断会漏掉"会话在跑但不出帧"的情况（实测踩过）
            if let d = chosen {
                try? camera.select(d)
            } else {
                try? camera.start(position: .front)
            }
            syncPreviewMirroring()
            highlightCamera()
            previewLayer?.connection?.videoOrientation = camera.orientation
            camera.requestKeyframe()
        }
    }

    @objc private func toggle() {
        if running { stopAll() } else { startAll() }
    }

    private func startAll() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] camOK in
            DispatchQueue.main.async {
                guard let self else { return }
                if !camOK {
                    self.statusLabel.text = "相机权限被拒绝，请到 设置 → PhoneMic 里开启"
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { micOK in
                    DispatchQueue.main.async { self.begin(micAllowed: micOK) }
                }
            }
        }
    }

    private func begin(micAllowed: Bool) {
        if micAllowed {
            do {
                try audio.start()
            } catch {
                statusLabel.text = "麦克风启动失败: \(error.localizedDescription)"
            }
        }
        server.start()
        video.start(width: 1280, height: 720, fps: 30)
        beacon.start()
        // 按手机当前朝向决定输出方向（竖着拿就输出竖图）
        if let o = MicVC.videoOrientation(from: UIDevice.current.orientation) {
            camera.applyOrientation(o)
        }
        do {
            if let d = chosen {
                try camera.select(d)
            } else {
                try camera.start(position: .front)
                chosen = camera.currentDevice
            }
            running = true
            button.setTitle("■  停止推流", for: .normal)
            button.backgroundColor = UIColor(red: 0.85, green: 0.30, blue: 0.30, alpha: 1)
            highlightCamera()
            syncPreviewMirroring()
            previewLayer?.connection?.videoOrientation = camera.orientation
            let name = chosen.map { CameraCore.title(for: $0) } ?? "摄像头"
            statusLabel.text = micAllowed
                ? "「\(name)」推流中，等待电脑连接…"
                : "「\(name)」仅视频推流（未拿到麦克风权限）"
        } catch {
            statusLabel.text = "摄像头启动失败: \(error.localizedDescription)"
        }
    }

    private func stopAll() {
        camera.stop()
        audio.stop()
        server.stop()
        video.stop()
        beacon.stop()
        running = false
        button.setTitle("●  开始推流", for: .normal)
        button.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        statusLabel.text = "未开始"
        meterLabel.text = "—"
        statsLabel.text = "—"
        highlightCamera()
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
