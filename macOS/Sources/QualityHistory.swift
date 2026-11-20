import Foundation

struct QualityPoint: Identifiable {
    var id: TimeInterval { time }

    let time: TimeInterval
    let segment: Int
    let receivedFrames: Int64
    let streamBytes: Int64
    let receiveMbps: Double?
    let bufferMs: Double
    let peakDBFS: Double
    let totalUnderruns: Int
    let totalDroppedFrames: Int
    let underruns: Int
    let droppedFrames: Int

    var droppedMs: Double { Double(droppedFrames) * 1000 / Double(PCM.rate) }
}

struct QualityHistory {
    static let span: TimeInterval = 60
    private(set) var points: [QualityPoint] = []

    mutating func append(_ sample: PlaybackSample, at time: TimeInterval, streamBytes: Int64? = nil) {
        let bytes = streamBytes ?? sample.receivedFrames * Int64(PCM.frameBytes)
        let previous = points.last
        if let previous, time <= previous.time { return }
        let continuous = previous.map { time - $0.time <= 1.5 && sample.receivedFrames >= $0.receivedFrames } ?? false
        let segment = continuous ? (previous?.segment ?? 0) : (previous?.segment ?? -1) + 1
        let baseline = continuous
            ? (points.last { $0.segment == segment && $0.time <= time - 1 }
               ?? points.first { $0.segment == segment })
            : nil
        let receiveMbps = baseline.flatMap { baseline -> Double? in
            let interval = time - baseline.time
            guard interval >= 0.15 else { return nil }
            let bits = Double(bytes - baseline.streamBytes) * 8
            return bits / interval / 1_000_000
        }
        let lastUnderruns = previous?.totalUnderruns ?? 0
        let lastDropped = previous?.totalDroppedFrames ?? 0
        points.append(QualityPoint(
            time: time,
            segment: segment,
            receivedFrames: sample.receivedFrames,
            streamBytes: bytes,
            receiveMbps: receiveMbps,
            bufferMs: max(0, sample.appBufferMs),
            peakDBFS: 20 * log10(max(0.001, min(1, sample.level))),
            totalUnderruns: sample.underruns,
            totalDroppedFrames: sample.droppedFrames,
            underruns: max(0, sample.underruns - lastUnderruns),
            droppedFrames: max(0, sample.droppedFrames - lastDropped)
        ))
        // Hold one point just before the visible window so connected lines
        // continue smoothly across the left edge as the window advances.
        if let first = points.firstIndex(where: { $0.time >= time - Self.span }), first > 1 {
            points.removeFirst(first - 1)
        }
    }
}
