import SwiftUI

struct QualityMonitor: View {
    let points: [QualityPoint]
    let active: Bool
    let targetBuffer: Int
    let backend: InputBackend

    @State private var metric: QualityMetric = .receive
    @State private var hover: Double?

    private var anchor: TimeInterval { points.last?.time ?? 0 }
    private var picked: QualityPoint? {
        guard let hover else { return nil }
        let requested = anchor + hover
        guard let first = points.first, requested >= first.time - 0.3 else { return nil }
        return points.min { abs($0.time - requested) < abs($1.time - requested) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Label("实时音频监控", systemImage: "waveform.path.ecg")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Picker("监控指标", selection: $metric) {
                    ForEach(QualityMetric.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                let shown = picked ?? points.last
                Text(shown.flatMap { metric.value($0) }.map { metric.valueLabel($0) } ?? "—")
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .foregroundStyle(metric.color)
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(metric.title) \(shown.flatMap { metric.value($0) }.map { metric.valueLabel($0) } ?? "暂无数据") \(metric.unit)")
                Text(metric.unit).foregroundStyle(.secondary).font(.system(size: 12))
                    .accessibilityHidden(true)
                if let picked {
                    Text(String(format: "%.1f 秒前", max(0, anchor - picked.time)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 3)
                }
                Spacer()
                HStack(spacing: 12) {
                    eventKey("缓冲不足", color: .orange)
                    eventKey("丢弃旧音频", color: Color(red: 0.97, green: 0.42, blue: 0.58))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            let domain = metric.domain(points, targetBuffer: targetBuffer, backend: backend)
            plot(domain: domain)
                .frame(height: 143)
                .overlay {
                    if points.isEmpty {
                        Text(active ? "正在等待音频数据…" : "连接后开始采样")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.32), in: Capsule())
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("最近 60 秒\(metric.title)曲线")

            HStack {
                if let picked, picked.underruns > 0 || picked.droppedFrames > 0 {
                    Text("这个采样点：缓冲不足 \(picked.underruns) 次，丢弃 \(Int(picked.droppedMs.rounded())) ms")
                        .foregroundStyle(.orange)
                } else {
                    Text(metric.note(backend: backend))
                }
                Spacer()
                Text(active ? "每 0.25 秒更新" : (points.isEmpty ? "最近 60 秒" : "已暂停 · 保留最后记录"))
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .onChange(of: metric) { _, _ in hover = nil }
        .onChange(of: points.isEmpty) { _, empty in if empty { hover = nil } }
    }

    private func plot(domain: ClosedRange<Double>) -> some View {
        let metric = self.metric
        let anchor = self.anchor
        let selected = self.picked
        let points = self.points
        return Canvas { context, size in
            let rect = plotRect(size)
            guard rect.width > 0, rect.height > 0 else { return }
            func x(_ seconds: Double) -> CGFloat {
                rect.maxX + CGFloat(seconds / QualityHistory.span) * rect.width
            }
            func y(_ value: Double) -> CGFloat {
                rect.maxY - CGFloat((value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)) * rect.height
            }
            func line(_ start: CGPoint, _ end: CGPoint) -> Path {
                Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                }
            }

            context.fill(Path(rect), with: .color(.black.opacity(0.14)))
            for tick in [-60.0, -45, -30, -15, 0] {
                let edge = x(tick)
                context.stroke(line(CGPoint(x: edge, y: rect.minY), CGPoint(x: edge, y: rect.maxY)),
                               with: .color(.white.opacity(0.075)), lineWidth: 1)
                let label = tick == 0 ? "现在" : "\(Int(-tick)) 秒前"
                let align: UnitPoint = tick == 0 ? .topTrailing : (tick == -60 ? .topLeading : .top)
                context.draw(Text(label).font(.system(size: 10)).foregroundStyle(.secondary),
                             at: CGPoint(x: edge, y: rect.maxY + 5), anchor: align)
            }
            for tick in metric.ticks(domain) {
                let edge = y(tick)
                context.stroke(line(CGPoint(x: rect.minX, y: edge), CGPoint(x: rect.maxX, y: edge)),
                               with: .color(.white.opacity(0.09)), lineWidth: 1)
                context.draw(Text(metric.axisLabel(tick)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary),
                             at: CGPoint(x: rect.minX - 7, y: edge), anchor: .trailing)
            }

            var plot = context
            plot.clip(to: Path(rect))
            if let reference = metric.reference(targetBuffer, backend: backend) {
                let edge = y(reference)
                plot.stroke(line(CGPoint(x: rect.minX, y: edge), CGPoint(x: rect.maxX, y: edge)),
                            with: .color(metric.color.opacity(0.39)),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            // Draw consecutive runs independently so a sleep or sampling gap
            // does not look like real audio interpolated across the gap.
            var run: [CGPoint] = []
            var segment = points.first?.segment
            func drawRun(_ run: [CGPoint]) {
                guard let first = run.first, let last = run.last, run.count >= 2 else { return }
                var trace = Path()
                trace.move(to: first)
                trace.addLines(run)
                var area = trace
                area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                area.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                area.closeSubpath()
                plot.fill(area, with: .linearGradient(
                    Gradient(colors: [metric.color.opacity(0.32), metric.color.opacity(0.04)]),
                    startPoint: CGPoint(x: rect.minX, y: rect.minY),
                    endPoint: CGPoint(x: rect.minX, y: rect.maxY)
                ))
                plot.stroke(trace, with: .color(metric.color),
                            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            }

            var gaps = Path(), drops = Path()
            for point in points {
                if point.segment != segment {
                    drawRun(run)
                    run.removeAll(keepingCapacity: true)
                    segment = point.segment
                }
                let edge = x(point.time - anchor)
                if let value = metric.value(point) {
                    run.append(CGPoint(x: edge, y: y(value)))
                }
                let upper = CGPoint(x: edge, y: rect.minY)
                let lower = CGPoint(x: edge, y: rect.maxY)
                if point.underruns > 0 {
                    gaps.move(to: upper); gaps.addLine(to: lower)
                }
                if point.droppedFrames > 0 {
                    let offset: CGFloat = point.underruns > 0 ? 2 : 0
                    drops.move(to: CGPoint(x: upper.x + offset, y: upper.y))
                    drops.addLine(to: CGPoint(x: lower.x + offset, y: lower.y))
                }
            }
            drawRun(run)
            let markStyle = StrokeStyle(lineWidth: 1, dash: [2, 3])
            plot.stroke(gaps, with: .color(.orange.opacity(0.78)), style: markStyle)
            plot.stroke(drops, with: .color(Color(red: 0.97, green: 0.42, blue: 0.58).opacity(0.68)), style: markStyle)

            if let selected {
                let edge = x(selected.time - anchor)
                plot.stroke(line(CGPoint(x: edge, y: rect.minY), CGPoint(x: edge, y: rect.maxY)),
                            with: .color(.white.opacity(0.42)), lineWidth: 1)
            }
            if let point = selected ?? points.last, let value = metric.value(point) {
                let center = CGPoint(x: x(point.time - anchor), y: y(value))
                let radius: CGFloat = selected == nil ? 2.7 : 3.6
                plot.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                          with: .color(metric.color))
            }
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            let rect = plotRect(geometry.size)
                            guard rect.width > 0, rect.contains(location) else {
                                hover = nil
                                return
                            }
                            hover = Double((location.x - rect.maxX) / rect.width) * QualityHistory.span
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 36, y: 7, width: max(0, size.width - 44), height: max(0, size.height - 26))
    }

    private func eventKey(_ name: String, color: Color) -> some View {
        Label(name, systemImage: "circle.fill")
            .labelStyle(MonitorLegendStyle(color: color))
    }
}

private struct MonitorLegendStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title
        }
    }
}

private enum QualityMetric: CaseIterable {
    case receive, buffer, level

    var title: String {
        switch self {
        case .receive: "接收速率"
        case .buffer: "Mac 缓冲"
        case .level: "音频电平"
        }
    }

    var unit: String {
        switch self {
        case .receive: "Mb/s"
        case .buffer: "ms"
        case .level: "dBFS"
        }
    }

    func note(backend: InputBackend) -> String {
        switch self {
        case .receive: "SSH 收到的 \(backend == .bluez ? "SBC" : "PCM") 数据率 · 约 1 秒滑动平均"
        case .buffer: "Mac 端排队量 · 虚线为目标缓冲"
        case .level: "PCM 峰值电平 · 音量调节前"
        }
    }

    var color: Color {
        switch self {
        case .receive: Color(red: 0.47, green: 0.92, blue: 0.83)
        case .buffer: Color(red: 0.44, green: 0.72, blue: 0.99)
        case .level: Color(red: 0.76, green: 0.63, blue: 0.99)
        }
    }

    func value(_ point: QualityPoint) -> Double? {
        switch self {
        case .receive: point.receiveMbps
        case .buffer: point.bufferMs
        case .level: point.peakDBFS
        }
    }

    func reference(_ targetBuffer: Int, backend: InputBackend) -> Double? {
        switch self {
        case .receive: backend == .pulse ? Double(PCM.rate * PCM.frameBytes * 8) / 1_000_000 : nil
        case .buffer: Double(targetBuffer)
        case .level: nil
        }
    }

    func domain(_ points: [QualityPoint], targetBuffer: Int, backend: InputBackend) -> ClosedRange<Double> {
        let peak = points.compactMap { value($0) }.max() ?? 0
        switch self {
        case .receive:
            let minimum = backend == .pulse ? 2.0 : 0.5
            return 0...max(minimum, ceil(peak / minimum) * minimum)
        case .buffer:
            return 0...max(80, ceil(max(peak, Double(targetBuffer) + 20) / 40) * 40)
        case .level:
            return -60...0
        }
    }

    func ticks(_ domain: ClosedRange<Double>) -> [Double] {
        if self == .level { return [-60, -40, -20, 0] }
        return [0, domain.upperBound / 2, domain.upperBound]
    }

    func axisLabel(_ raw: Double) -> String {
        self == .receive ? String(format: "%.1f", raw) : String(format: "%.0f", raw)
    }

    func valueLabel(_ raw: Double) -> String {
        self == .receive ? String(format: "%.2f", raw) : String(format: "%.0f", raw)
    }
}
