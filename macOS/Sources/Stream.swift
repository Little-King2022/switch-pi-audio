import Foundation

enum InputBackend: String, CaseIterable {
    case pulse, bluez

    var label: String {
        switch self {
        case .pulse: "PulseAudio"
        case .bluez: "BlueZ 直读"
        }
    }
}

private final class WireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0

    func add(_ count: Int) { lock.withLock { bytes += Int64(count) } }
    func read() -> Int64 { lock.withLock { bytes } }
}

final class SSHStream: @unchecked Sendable {
    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let standardInput = Pipe()
    private let lock = NSLock()
    private var messages = Data()
    private var stopped = false

    private static func sshArguments(host: String, command: String) throws -> [String] {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.range(of: #"^[A-Za-z0-9][A-Za-z0-9._@-]{0,125}$"#, options: .regularExpression) != nil else {
            throw PlayerError("请输入 SSH 别名，例如 pi-audio，或 user@host。")
        }
        return ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", host, command]
    }

    static func changeBackend(host: String, backend: InputBackend) async throws {
        let arguments = try sshArguments(host: host, command: "/usr/libexec/switch-audio-backend \(backend.rawValue)")
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw PlayerError(message.isEmpty ? "切换树莓派后端失败。" : message)
            }
        }.value
    }

    init(host: String, source: String, backend: InputBackend = .pulse, receive: @escaping @Sendable (Data) -> Void,
         ended: @escaping @Sendable (Int32, String) -> Void) throws {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard backend != .pulse || source.isEmpty ||
            source.range(of: #"^[A-Za-z0-9_.-]{1,160}$"#, options: .regularExpression) != nil else {
            throw PlayerError("输入名称可留空，或填写 PulseAudio 的完整输入名称。")
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try Self.sshArguments(host: host, command: "sh -s")
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock()
            let manual = self.stopped
            let text = String(decoding: self.messages, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            self.lock.unlock()
            if !manual { ended(p.terminationStatus, text) }
        }

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { receive(data) }
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock()
            self.messages.append(data)
            if self.messages.count > 4096 { self.messages.removeFirst(self.messages.count - 4096) }
            self.lock.unlock()
        }
        do {
            try process.run()
            let text = backend == .pulse ? "requested='\(source)'\n" + Self.remote
                : "exec /usr/libexec/switch-audio-sbc --read\n"
            try standardInput.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try standardInput.fileHandleForWriting.close()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    static let remote = #"""
    set -eu
    export PULSE_SERVER=unix:/var/run/pulse/native
    sources=$(pactl list short sources)
    if [ -n "$requested" ]; then
      source=$(printf '%s\n' "$sources" | awk -v name="$requested" '$2==name && $2 ~ /^bluez_(source|input)[.]/ {print $2; exit}')
    else
      source=$(printf '%s\n' "$sources" | awk '$2 ~ /^bluez_(source|input)[.]/ {count++; name=$2} END {if (count==1) print name}')
    fi
    if [ -z "$source" ]; then
      printf '%s\n' '未找到唯一可用的蓝牙输入。请在 Switch 上连接 Switch-Pi-Audio，或在 App 里指定输入。' >&2
      exit 3
    fi
    exec parec --raw --device="$source" --format=s16le --rate=48000 --channels=2
    """# + "\n"
}

@MainActor
final class ReceiverModel: ObservableObject {
    enum Phase: Equatable {
        case disconnected, connecting, buffering, playing, error
        var label: String {
            switch self {
            case .disconnected: "未连接"
            case .connecting: "正在连接"
            case .buffering: "正在缓冲"
            case .playing: "正在播放"
            case .error: "连接中断"
            }
        }
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var metrics: PlaybackSample?
    @Published private(set) var qualityHistory = QualityHistory()
    @Published private(set) var monitoredBuffer: Int?
    @Published private(set) var monitoredBackend: InputBackend?
    @Published private(set) var message = ""
    @Published private(set) var switchingBackend = false
    @Published private(set) var backendMessage = ""
    @Published private(set) var outputs = OutputDevice.available()
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "sshHost") }
    }
    @Published var source: String {
        didSet { UserDefaults.standard.set(source, forKey: "sourceName") }
    }
    @Published var backend: InputBackend {
        didSet {
            UserDefaults.standard.set(backend.rawValue, forKey: "inputBackend")
            backendMessage = ""
        }
    }
    @Published var outputID: String {
        didSet { UserDefaults.standard.set(outputID, forKey: "outputID") }
    }
    @Published var bufferMs: Int {
        didSet { UserDefaults.standard.set(bufferMs, forKey: "bufferMs") }
    }
    @Published var blockMs: Int {
        didSet { UserDefaults.standard.set(blockMs, forKey: "blockMs") }
    }
    @Published var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: "volume")
            player?.setVolume(Float(volume))
        }
    }

    private var player: PCMPlayer?
    private var stream: SSHStream?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private let qualityLog: FileHandle? = {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--quality-log"), arguments.indices.contains(flag + 1) else { return nil }
        let path = arguments[flag + 1]
        guard FileManager.default.createFile(atPath: path, contents: nil) else { return nil }
        return FileHandle(forWritingAtPath: path)
    }()

    var active: Bool { stream != nil }
    var selectedOutput: OutputDevice? { outputs.first { $0.id == outputID } }

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "sshHost") ?? "pi-audio"
        source = defaults.string(forKey: "sourceName") ?? ""
        if CommandLine.arguments.contains("--bluez") {
            backend = .bluez
        } else if CommandLine.arguments.contains("--pulse") {
            backend = .pulse
        } else {
            backend = InputBackend(rawValue: defaults.string(forKey: "inputBackend") ?? "") ?? .pulse
        }
        outputID = defaults.string(forKey: "outputID") ?? "BuiltInSpeakerDevice"
        bufferMs = (defaults.object(forKey: "bufferMs") as? Int).flatMap { [40, 60, 80, 120].contains($0) ? $0 : nil } ?? 40
        blockMs = (defaults.object(forKey: "blockMs") as? Int).flatMap { [10, 15, 20].contains($0) ? $0 : nil } ?? 10
        volume = min(1, max(0, defaults.object(forKey: "volume") as? Double ?? 0.8))
        if !outputs.contains(where: { $0.id == outputID }) {
            outputID = outputs.first?.id ?? ""
        }
    }

    func refreshOutputs() {
        outputs = OutputDevice.available()
        if !active, selectedOutput == nil { outputID = outputs.first?.id ?? "" }
    }

    func changeBackend() async {
        guard !active, !switchingBackend else { return }
        switchingBackend = true
        backendMessage = ""
        defer { switchingBackend = false }
        do {
            try await SSHStream.changeBackend(host: host, backend: backend)
            backendMessage = "树莓派已启用\(backend.label)。请确认 Switch 已连接，再点「连接」。"
        } catch {
            backendMessage = error.localizedDescription
        }
    }

    func connect() {
        if active || switchingBackend { return }
        refreshOutputs()
        guard let selectedOutput else { fail("找不到可用的音频输出。"); return }
        message = ""
        metrics = nil
        qualityHistory = QualityHistory()
        monitoredBuffer = bufferMs
        monitoredBackend = backend
        phase = .connecting
        generation = UUID()
        let token = generation
        do {
            let engine = try PCMPlayer(device: selectedOutput, bufferMs: bufferMs, blockMs: blockMs, volume: Float(volume))
            let mode = backend
            let decoder = mode == .bluez ? try SBCDecoder() : nil
            let wire = WireCounter()
            player = engine
            stream = try SSHStream(host: host, source: source, backend: mode, receive: { data in
                    wire.add(data.count)
                    engine.append(decoder?.decode(data) ?? data)
                },
                ended: { [weak self] exitCode, stderr in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.fail(stderr.isEmpty ? "SSH 音频流已结束（\(exitCode)）。" : stderr)
                    }
                })
            let start = ProcessInfo.processInfo.systemUptime
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.generation == token, let engine = self.player else { return }
                    let status = engine.sample()
                    let now = ProcessInfo.processInfo.systemUptime
                    self.metrics = status
                    if status.receivedFrames > 0 || !self.qualityHistory.points.isEmpty {
                        self.qualityHistory.append(status, at: now, streamBytes: wire.read())
                        if let log = self.qualityLog, let point = self.qualityHistory.points.last {
                            let line = "\(mode.rawValue),\(now - start),\(status.receivedFrames),\(point.receiveMbps ?? 0),\(point.bufferMs),\(point.peakDBFS),\(point.totalUnderruns),\(point.totalDroppedFrames)\n"
                            try? log.write(contentsOf: Data(line.utf8))
                        }
                    }
                    if let error = status.error { self.fail(error); return }
                    if status.started { self.phase = status.rebuffering ? .buffering : .playing }
                    else if status.receivedFrames > 0 { self.phase = .buffering }
                    if !status.started && now - start > 14 {
                        self.fail("SSH 已启动，但暂时没有音频数据。请确认 Switch 已连接并正在播放。")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func disconnect() {
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        stream?.stop()
        stream = nil
        player?.close()
        player = nil
        metrics = nil
        message = ""
        phase = .disconnected
    }

    private func fail(_ reason: String) {
        disconnect()
        message = reason
        phase = .error
    }
}
