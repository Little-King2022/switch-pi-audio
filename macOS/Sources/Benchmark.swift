import AudioToolbox
import AVFoundation
import Foundation
import SwiftUI

private let markerFrequency = 1_500.0

private func hostSeconds() -> Double {
    AVAudioTime.seconds(forHostTime: mach_absolute_time())
}

private final class MarkerMic: @unchecked Sendable {
    private let lock = NSLock()
    private let callbacks = DispatchQueue(label: "local.switch-pi.marker-microphone")
    private var recording: AudioQueueRef?
    private var closed = false
    private var found = [Double]()
    private var wasTone = false
    private let length = 480
    private let cosine: [Double]
    private let sine: [Double]

    init() throws {
        cosine = (0..<length).map { cos(2 * .pi * markerFrequency * Double($0) / 48000) }
        sine = (0..<length).map { sin(2 * .pi * markerFrequency * Double($0) / 48000) }
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32,
            mReserved: 0)
        var q: AudioQueueRef?
        let create = AudioQueueNewInputWithDispatchQueue(&q, &format, 0, callbacks) { [weak self] queue, buffer, stamp, _, _ in
            self?.received(queue, buffer, stamp.pointee)
        }
        guard create == noErr, let q else { throw PlayerError("无法启动测量用的麦克风（\(create)）。") }
        recording = q
        do {
            try verify(setQueueDevice(q, uid: "BuiltInMicrophoneDevice"))
            for _ in 0..<4 {
                var buffer: AudioQueueBufferRef?
                try verify(AudioQueueAllocateBuffer(q, UInt32(length * 4), &buffer))
                guard let buffer else { throw PlayerError("无法分配麦克风缓冲。") }
                try verify(AudioQueueEnqueueBuffer(q, buffer, 0, nil))
            }
            try verify(AudioQueueStart(q, nil))
        } catch {
            close()
            throw error
        }
    }

    private func verify(_ status: OSStatus) throws {
        if status != noErr { throw PlayerError("内置麦克风不可用（\(status)）。") }
    }

    private func received(_ q: AudioQueueRef, _ buffer: AudioQueueBufferRef, _ time: AudioTimeStamp) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let count = Int(buffer.pointee.mAudioDataByteSize) / 4
        if count == length {
            let values = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
            var re = 0.0, im = 0.0, energy = 0.0
            for i in 0..<count {
                let v = Double(values[i])
                re += v * cosine[i]
                im += v * sine[i]
                energy += v * v
            }
            let magnitude = re * re + im * im
            let tone = magnitude > 0.48 * Double(count) * energy * 0.5 &&
                       sqrt(max(0, energy / Double(count))) > 0.00032
            if tone && !wasTone {
                let at = time.mFlags.contains(.hostTimeValid)
                    ? AVAudioTime.seconds(forHostTime: time.mHostTime) : hostSeconds() - 0.01
                found.append(at)
            }
            wasTone = tone
        }
        AudioQueueEnqueueBuffer(q, buffer, 0, nil)
    }

    func matches(_ sent: [Double]) -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return sent.compactMap { start in
            found.first(where: { $0 >= start - 0.012 && $0 < start + 0.65 })
                .map { max(0, ($0 - start) * 1000) }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let q = recording
        recording = nil
        lock.unlock()
        if let q { AudioQueueDispose(q, true) }
    }

    deinit { close() }
}

struct BenchmarkResult {
    let legacy: [Double]
    let native: [Double]
    var oldMedian: Double { median(legacy) }
    var newMedian: Double { median(native) }
    private func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle-1] + sorted[middle]) / 2 : sorted[middle]
    }
}

private struct BenchmarkTest {
    let output: OutputDevice
    let buffer: Int
    let block: Int
    static let markers: Set<Int> = [42, 82, 122, 162, 202]

    func run(progress: @escaping @Sendable (String) -> Void) async throws -> BenchmarkResult {
        let ffmpeg = try findFFmpeg()
        let index = try outputIndex(ffmpeg)
        let mic = try MarkerMic()
        defer { mic.close() }
        // Let the microphone clock settle before starting the first output.
        try await Task.sleep(nanoseconds: 300_000_000)
        progress("测量现有 FFmpeg 播放…")
        let old = try await measureFFmpeg(ffmpeg: ffmpeg, index: index, mic: mic)
        progress("测量 Core Audio 播放…")
        let new = try await measureNative(mic: mic)
        guard old.count >= 3, new.count >= 3 else {
            throw PlayerError("未能收到足够的测量音（FFmpeg \(old.count)/5，Core Audio \(new.count)/5）。请调高 Mac 扬声器音量，保持周围安静再试。")
        }
        return BenchmarkResult(legacy: old, native: new)
    }

    private func measureFFmpeg(ffmpeg: URL, index: String, mic: MarkerMic) async throws -> [Double] {
        let process = Process()
        let input = Pipe()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "s16le",
            "-ar", "48000", "-ch_layout", "stereo", "-i", "pipe:0",
            "-audio_device_index", index, "-f", "audiotoolbox", "-"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let stamps = try await feed { data in
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try input.fileHandleForWriting.close()
        try await Task.sleep(nanoseconds: 450_000_000)
        return mic.matches(stamps)
    }

    private func measureNative(mic: MarkerMic) async throws -> [Double] {
        let player = try PCMPlayer(device: output, bufferMs: buffer, blockMs: block, volume: 1)
        defer { player.close() }
        let stamps = try await feed { player.append($0) }
        try await Task.sleep(nanoseconds: 380_000_000)
        if let error = player.sample().error { throw PlayerError(error) }
        return mic.matches(stamps)
    }

    private func feed(_ write: (Data) throws -> Void) async throws -> [Double] {
        let start = hostSeconds()
        let quiet = Data(count: PCM.bytes(ms: 20))
        let markers = Self.markers
        let tone = (0..<1920).map { i -> Int16 in
            let envelope = min(1, Double(min(i, 1919 - i)) / 96)
            return Int16((0.18 * 32767 * envelope * sin(2 * .pi * markerFrequency * Double(i) / 48000)).rounded())
        }
        var stamps = [Double]()
        for step in 0..<230 {
            try Task.checkCancellation()
            let next = start + Double(step) * 0.02
            let delay = next - hostSeconds()
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            let beginning = markers.contains(step)
            if beginning || markers.contains(step - 1) {
                let offset = beginning ? 0 : 960
                var stereo = [Int16]()
                stereo.reserveCapacity(1920)
                for sample in tone[offset..<(offset + 960)] { stereo.append(sample); stereo.append(sample) }
                let data = stereo.withUnsafeBytes { Data($0) }
                if beginning { stamps.append(hostSeconds()) }
                try write(data)
            } else {
                try write(quiet)
            }
        }
        return stamps
    }

    private func findFFmpeg() throws -> URL {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let candidate = dirs.map({ $0 + "/ffmpeg" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw PlayerError("找不到 FFmpeg。播放功能可用，延迟对比需要原方案的 FFmpeg。")
        }
        return URL(fileURLWithPath: candidate)
    }

    private func outputIndex(_ ffmpeg: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                             "-t", "0.01", "-list_devices", "true", "-f", "audiotoolbox", "-"]
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        for line in text.split(separator: "\n") where line.hasSuffix(", " + output.id) {
            if let pair = line.range(of: #"\[\d+\]"#, options: .regularExpression) {
                return String(line[pair].dropFirst().dropLast())
            }
        }
        throw PlayerError("FFmpeg 找不到相同的内置扬声器。")
    }
}

@MainActor
final class BenchmarkModel: ObservableObject {
    @Published var running = false
    @Published var stage = ""
    @Published var result: BenchmarkResult?
    @Published var failure = ""
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(output: OutputDevice?, buffer: Int, block: Int) {
        guard !running else { return }
        guard let output, output.id == "BuiltInSpeakerDevice" else {
            failure = "测量需要选择 MacBook 内置扬声器。"
            return
        }
        failure = ""
        result = nil
        stage = "等待麦克风权限…"
        running = true
        generation = UUID()
        let token = generation
        task = Task { [weak self] in
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                if self?.generation == token {
                    self?.failure = "系统尚未授权麦克风。可在「系统设置 → 隐私与安全性 → 麦克风」中授权后重试。"
                    self?.running = false
                }
                return
            }
            guard !Task.isCancelled else { return }
            let config = BenchmarkTest(output: output, buffer: buffer, block: block)
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                try await config.run { [weak self] text in
                    Task { @MainActor in
                        if self?.generation == token { self?.stage = text }
                    }
                }
            }
            do {
                let measurement = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: { worker.cancel() })
                if self?.generation == token {
                    self?.result = measurement
                    let data: [String: [Double]] = ["ffmpegMs": measurement.legacy, "coreAudioMs": measurement.native]
                    if let json = try? JSONSerialization.data(withJSONObject: data),
                       let line = String(data: json, encoding: .utf8) {
                        print("BENCHMARK \(line)")
                        fflush(stdout)
                    }
                }
            } catch {
                if self?.generation == token && !(error is CancellationError) {
                    self?.failure = error.localizedDescription
                    print("BENCHMARK_ERROR \(error.localizedDescription)")
                    fflush(stdout)
                }
            }
            if self?.generation == token { self?.running = false }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        stage = ""
        running = false
    }
}

struct BenchmarkView: View {
    @ObservedObject var model: BenchmarkModel
    let output: OutputDevice?
    let buffer: Int
    let block: Int
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("延迟对比").font(.title2.bold())
            Text("用内置扬声器播放短测试音，内置麦克风检测到达时间。测量覆盖 Mac 播放段，不包含 Switch、蓝牙或网络。不会保存录音。")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if model.running {
                HStack { ProgressView().controlSize(.small); Text(model.stage) }
            }
            if let result = model.result {
                Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 8) {
                    GridRow { Text("FFmpeg"); Text(String(format: "%.0f ms", result.oldMedian)).monospacedDigit() }
                    GridRow { Text("Core Audio"); Text(String(format: "%.0f ms", result.newMedian)).monospacedDigit() }
                    GridRow { Text("差值"); Text(String(format: "%.0f ms", result.oldMedian - result.newMedian)).monospacedDigit() }
                }
                Text("各路径用 5 个脉冲测试，取识别到的样本中位数。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.failure.isEmpty {
                Text(model.failure).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("关闭") { model.cancel(); dismiss() }
                Button("开始测量") { model.start(output: output, buffer: buffer, block: block) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.running)
            }
        }
        .padding(24)
        .frame(width: 430)
        .onDisappear { model.cancel() }
        .task {
            if CommandLine.arguments.contains("--measure") {
                model.start(output: output, buffer: buffer, block: block)
            }
        }
    }
}
