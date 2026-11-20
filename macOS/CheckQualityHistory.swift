import Foundation

@main
struct Check {
    static func main() {
        var history = QualityHistory()
        func sample(frames: Int64, underruns: Int = 0, drops: Int = 0, level: Double = 0.5) -> PlaybackSample {
            PlaybackSample(started: true, rebuffering: false, appBufferMs: 49, receivedFrames: frames,
                           underruns: underruns, droppedFrames: drops, level: level, error: nil)
        }
        history.append(sample(frames: 12_000), at: 10)
        precondition(history.points.last?.receiveMbps == nil)
        history.append(sample(frames: 24_000, underruns: 2, drops: 480), at: 10.25)
        let item = history.points.last!
        precondition(abs(item.receiveMbps! - 1.536) < 0.001 && item.bufferMs == 49)
        precondition(item.underruns == 2 && item.droppedMs == 10)
        precondition(abs(item.peakDBFS + 6.0206) < 0.001)
        history.append(sample(frames: 25_000, underruns: 2, drops: 480, level: 0), at: 12)
        precondition(history.points.last!.receiveMbps == nil)
        precondition(history.points.last!.segment == item.segment + 1)
        precondition(history.points.last!.peakDBFS == -60)
        for index in 1...500 {
            history.append(sample(frames: 25_000 + Int64(12_000 * index)), at: 12 + 0.25 * Double(index))
        }
        precondition(history.points.count == 242)
        print("Verified PCM bitrate, quality event deltas, gaps and the bounded rolling window.")
    }
}
