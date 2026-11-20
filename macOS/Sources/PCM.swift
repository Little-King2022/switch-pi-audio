import AudioToolbox
import CoreAudio
import Foundation

enum PCM {
    static let rate = 48_000
    static let frameBytes = 4
    static var format: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    }
    static func bytes(ms: Int) -> Int { rate / 1000 * ms * frameBytes }
    static func ms(bytes: Int) -> Double { Double(bytes) / Double(rate * frameBytes) * 1000 }
}

struct OutputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let builtIn: Bool

    static func available() -> [OutputDevice] {
        var property = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0,
                  let uid = string(device, kAudioDevicePropertyDeviceUID),
                  let name = string(device, kAudioObjectPropertyName) else { return nil }
            var transport: UInt32 = 0
            var length = UInt32(MemoryLayout<UInt32>.size)
            var transportProperty = address(kAudioDevicePropertyTransportType)
            let ok = AudioObjectGetPropertyData(device, &transportProperty, 0, nil, &length, &transport) == noErr
            return OutputDevice(id: uid, name: name, builtIn: ok && transport == kAudioDeviceTransportTypeBuiltIn)
        }.sorted { lhs, rhs in
            if lhs.id == "BuiltInSpeakerDevice" { return rhs.id != lhs.id }
            if rhs.id == "BuiltInSpeakerDevice" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var length = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &length, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

// All ring operations are serialized by PCMPlayer's lock. Byte offsets are
// maintained across partial pipe reads; an eviction always removes whole frames.
private final class PCMRing {
    private let capacity = 262_144
    private let storage: UnsafeMutableRawPointer
    private var read = 0
    private(set) var count = 0

    init() { storage = .allocate(byteCount: capacity, alignment: 16) }
    deinit { storage.deallocate() }

    func drop(_ bytes: Int) {
        read = (read + bytes) % capacity
        count -= bytes
    }

    func append(_ data: Data) -> Int {
        let excess = max(0, count + data.count - capacity)
        let dropped = (excess + 3) & ~3
        let fromRing = min(count, dropped)
        drop(fromRing)
        let skip = dropped - fromRing
        let size = data.count - skip
        guard size > 0 else { return dropped }
        let write = (read + count) % capacity
        let first = min(size, capacity - write)
        data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress?.advanced(by: skip) else { return }
            memcpy(storage.advanced(by: write), start, first)
            if size > first { memcpy(storage, start.advanced(by: first), size - first) }
        }
        count += size
        return dropped
    }

    func take(_ bytes: Int, into output: UnsafeMutableRawPointer) {
        let first = min(bytes, capacity - read)
        memcpy(output, storage.advanced(by: read), first)
        if bytes > first { memcpy(output.advanced(by: first), storage, bytes - first) }
        drop(bytes)
    }
}

struct PlaybackSample {
    let started: Bool
    let rebuffering: Bool
    let appBufferMs: Double
    let receivedFrames: Int64
    let underruns: Int
    let droppedFrames: Int
    let level: Double
    let error: AppMessage?
}

final class PCMPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "local.switch-pi.audio-queue", qos: .userInteractive)
    private let ring = PCMRing()
    private let blockBytes: Int
    private let targetBytes: Int
    private let maxBytes: Int
    private let bufferCount = 2
    private var queue: AudioQueueRef?
    private var buffers = [AudioQueueBufferRef]()
    private var sentFrames: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var started = false
    private var refilling = false
    private var closed = false
    private var underruns = 0
    private var droppedFrames = 0
    private var level: Double = 0
    private var error: AppMessage?

    init(device: OutputDevice, bufferMs: Int, blockMs: Int, volume: Float) throws {
        let block = min(max(blockMs, 10), 20)
        let target = min(200, max(bufferMs, block * 2))
        blockBytes = PCM.bytes(ms: block)
        targetBytes = PCM.bytes(ms: target)
        maxBytes = PCM.bytes(ms: target + max(25, 2 * block))
        var format = PCM.format
        var result: AudioQueueRef?
        try check(AudioQueueNewOutputWithDispatchQueue(&result, &format, 0, callbackQueue) { [weak self] _, buffer in
            self?.completed(buffer)
        }, "audio.create")
        guard let result else { throw PlayerError(AppMessage("error.audio_create")) }
        queue = result
        do {
            try check(setQueueDevice(result, uid: device.id), "audio.select")
            for _ in 0..<bufferCount {
                var buffer: AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(result, UInt32(blockBytes), &buffer), "audio.allocate")
                guard let buffer else { throw PlayerError(AppMessage("error.audio_allocate")) }
                buffers.append(buffer)
            }
            try check(AudioQueueSetParameter(result, kAudioQueueParam_Volume, volume), "audio.volume")
        } catch {
            close()
            throw error
        }
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let queue, !closed, error == nil else { return }
        receivedBytes += Int64(data.count)
        droppedFrames += ring.append(data) / PCM.frameBytes
        let scheduled = started && !refilling ? bufferCount * blockBytes : 0
        if ring.count + scheduled > maxBytes {
            let desired = max(2 * blockBytes, targetBytes - scheduled)
            let discard = ((ring.count - desired) / PCM.frameBytes) * PCM.frameBytes
            ring.drop(discard)
            droppedFrames += discard / PCM.frameBytes
        }
        guard !started, ring.count >= targetBytes else { return }
        for buffer in buffers { fill(buffer, queue: queue) }
        guard error == nil else { return }
        let status = AudioQueueStart(queue, nil)
        if status == noErr { started = true }
        else { error = AppMessage("error.audio_start", .integer(Int64(status))) }
    }

    func setVolume(_ volume: Float) {
        lock.lock()
        defer { lock.unlock() }
        if let queue, !closed { AudioQueueSetParameter(queue, kAudioQueueParam_Volume, volume) }
    }

    private func completed(_ buffer: AudioQueueBufferRef) {
        lock.lock()
        defer { lock.unlock() }
        guard let queue, !closed, error == nil else { return }
        fill(buffer, queue: queue)
    }

    private func fill(_ buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        if refilling && ring.count >= targetBytes { refilling = false }
        if !refilling && ring.count < blockBytes {
            refilling = true
            underruns += 1
        }
        if refilling {
            memset(buffer.pointee.mAudioData, 0, blockBytes)
            level *= 0.7
        } else {
            ring.take(blockBytes, into: buffer.pointee.mAudioData)
            let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
            var peak: Int = 0
            for i in stride(from: 0, to: blockBytes / 2, by: 8) {
                peak = max(peak, abs(Int(samples[i])))
            }
            level = max(level * 0.72, Double(peak) / 32768)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(blockBytes)
        let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if status == noErr { sentFrames += Int64(blockBytes / PCM.frameBytes) }
        else { error = AppMessage("error.audio_enqueue", .integer(Int64(status))) }
    }

    func sample() -> PlaybackSample {
        lock.lock()
        defer { lock.unlock() }
        var framesInOutput = started ? Int64(bufferCount * blockBytes / PCM.frameBytes) : 0
        if let queue, started {
            var time = AudioTimeStamp()
            if AudioQueueGetCurrentTime(queue, nil, &time, nil) == noErr,
               time.mFlags.contains(.sampleTimeValid), time.mSampleTime.isFinite {
                framesInOutput = max(0, sentFrames - Int64(max(0, time.mSampleTime)))
            }
        }
        return PlaybackSample(started: started, rebuffering: refilling,
            appBufferMs: PCM.ms(bytes: ring.count) + Double(framesInOutput) * 1000 / Double(PCM.rate),
            receivedFrames: receivedBytes / 4, underruns: underruns, droppedFrames: droppedFrames,
            level: level, error: error)
    }

    func close() {
        lock.lock()
        let disposing = queue
        queue = nil
        closed = true
        lock.unlock()
        if let disposing { AudioQueueDispose(disposing, true) }
    }

    deinit { close() }
}

func setQueueDevice(_ queue: AudioQueueRef, uid: String) -> OSStatus {
    let value = uid as CFString
    var reference = Unmanaged.passUnretained(value)
    return withExtendedLifetime(value) {
        withUnsafePointer(to: &reference) { pointer in
            AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, pointer,
                                  UInt32(MemoryLayout<Unmanaged<CFString>>.size))
        }
    }
}

private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw PlayerError(AppMessage("error.audio_operation", .label(operation), .integer(Int64(status)))) }
}
