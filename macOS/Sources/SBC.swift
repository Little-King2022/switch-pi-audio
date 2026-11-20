import Foundation

// One instance is fed by the SSH stdout handler for the life of a stream.
final class SBCDecoder: @unchecked Sendable {
    private let decoder: OpaquePointer
    private var pending = Data()
    private var samples = [Int16](repeating: 0, count: 256)

    init() throws {
        guard let decoder = switch_sbc_create() else { throw PlayerError(AppMessage("error.sbc_init")) }
        self.decoder = decoder
    }

    deinit { switch_sbc_destroy(decoder) }

    func decode(_ data: Data) -> Data {
        pending.append(data)
        var consumed = 0
        var output = Data()
        let decoder = self.decoder
        pending.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            guard let base = input.bindMemory(to: UInt8.self).baseAddress else { return }
            samples.withUnsafeMutableBufferPointer { samples in
                guard let pcm = samples.baseAddress else { return }
                while consumed < input.count {
                    var bytes: UInt32 = 0
                    let frame = switch_sbc_decode(decoder, base + consumed, input.count - consumed, pcm, &bytes)
                    if frame == 0 { break }
                    consumed += frame
                    if bytes > 0 {
                        output.append(UnsafeRawPointer(pcm).assumingMemoryBound(to: UInt8.self), count: Int(bytes))
                    }
                }
            }
        }
        pending.removeFirst(consumed)
        return output
    }
}
