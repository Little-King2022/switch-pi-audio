import AppKit
import SwiftUI

@main
struct SwitchPiAudioApp: App {
    var body: some Scene {
        Window("Switch 音频", id: "receiver") {
            ReceiverView()
        }
        .defaultSize(width: 790, height: 748)
        .windowResizability(.contentMinSize)
    }
}

private let ink = Color(red: 0.055, green: 0.067, blue: 0.10)
private let panel = Color(red: 0.092, green: 0.112, blue: 0.16)
private let field = Color(red: 0.063, green: 0.083, blue: 0.125)
private let mint = Color(red: 0.47, green: 0.92, blue: 0.83)
private let secondary = Color(red: 0.63, green: 0.69, blue: 0.79)

struct ReceiverView: View {
    @StateObject private var model = ReceiverModel()
    @StateObject private var benchmark = BenchmarkModel()
    @State private var showBenchmark = false
    @State private var didLaunch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                header
                statusPanel
                card {
                    QualityMonitor(points: model.qualityHistory.points, active: model.active,
                                   targetBuffer: model.monitoredBuffer ?? model.bufferMs,
                                   backend: model.monitoredBackend ?? model.backend)
                }
                HStack(alignment: .top, spacing: 16) {
                    connection.frame(maxWidth: .infinity)
                    output.frame(maxWidth: .infinity)
                }
                HStack {
                    Text("Switch → 蓝牙 → 树莓派 → SSH → Core Audio")
                        .foregroundStyle(secondary)
                    Spacer()
                    Button {
                        showBenchmark = true
                    } label: {
                        Label("延迟对比", systemImage: "stopwatch")
                    }
                    .buttonStyle(.link)
                    .tint(mint)
                    .disabled(model.active)
                    .help("先断开播放，再用麦克风比较 Mac 本地播放器的延迟。")
                }
                .font(.system(size: 12))
            }
            .padding(26)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 680, minHeight: 535)
        .background {
            LinearGradient(colors: [Color(red: 0.085, green: 0.12, blue: 0.18), ink],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .tint(mint)
        .sheet(isPresented: $showBenchmark) {
            BenchmarkView(model: benchmark, output: model.selectedOutput,
                          buffer: model.bufferMs, block: model.blockMs)
        }
        .onAppear {
            guard !didLaunch else { return }
            didLaunch = true
            if CommandLine.arguments.contains("--benchmark") { showBenchmark = true }
            if CommandLine.arguments.contains("--connect") { model.connect() }
        }
        .onDisappear {
            model.disconnect()
            benchmark.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.37, blue: 0.42),
                                                 Color(red: 0.10, green: 0.23, blue: 0.34)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(mint)
            }
            .frame(width: 54, height: 54)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Switch 音频").font(.system(size: 29, weight: .semibold))
                Text("从树莓派接收游戏声音")
                    .font(.system(size: 13))
                    .foregroundStyle(secondary)
            }
            Spacer()
            Button {
                if model.active { model.disconnect() }
                else { model.connect() }
            } label: {
                Label(model.active ? "断开" : "连接",
                      systemImage: model.active ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 10)
                    .foregroundStyle(model.active ? Color.white : ink)
                    .background(model.active ? Color.white.opacity(0.10) : mint, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.switchingBackend)
        }
        .accessibilityElement(children: .contain)
    }

    private var connection: some View {
        card {
            sectionTitle("连接", symbol: "network")
            label("SSH 地址")
            TextField("pi-audio", text: $model.host)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .accessibilityLabel("SSH 地址")
                .disabled(model.active || model.switchingBackend)
            label("音频后端")
            HStack {
                Picker("音频后端", selection: $model.backend) {
                    ForEach(InputBackend.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
                .labelsHidden()
                Button(model.switchingBackend ? "正在切换…" : "切换树莓派后端") {
                    Task { await model.changeBackend() }
                }
                .help("切换会中断当前蓝牙连接，之后在 Switch 上重新连接。")
            }
            .disabled(model.active || model.switchingBackend)
            if model.backend == .pulse {
                TextField("PulseAudio 输入 · 留空自动识别", text: $model.source)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel("PulseAudio 输入名称")
                    .disabled(model.active || model.switchingBackend)
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(model.backendMessage.isEmpty ? "先在 Switch 上连接 Switch-Pi-Audio。" : model.backendMessage)
            }
            .font(.system(size: 11))
            .foregroundStyle(secondary)
            .padding(.top, 2)
        }
    }

    private var output: some View {
        card {
            sectionTitle("播放", symbol: "speaker.wave.2")
            HStack {
                label("输出设备")
                Spacer()
                Button { model.refreshOutputs() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(secondary)
                    .help("刷新输出设备")
                    .accessibilityLabel("刷新输出设备")
                    .disabled(model.active)
            }
            Picker("输出设备", selection: $model.outputID) {
                if model.outputs.isEmpty { Text("无可用设备").tag("") }
                ForEach(model.outputs) { device in
                    Text(device.id == "BuiltInSpeakerDevice" ? "MacBook 内置扬声器" : device.name)
                        .tag(device.id)
                }
            }
            .labelsHidden()
            .disabled(model.active)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    label("目标缓冲")
                    Picker("目标缓冲", selection: $model.bufferMs) {
                        ForEach([40, 60, 80, 120], id: \.self) { Text("\($0) ms").tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    label("播放块长")
                    Picker("播放块长", selection: $model.blockMs) {
                        ForEach([10, 15, 20], id: \.self) { Text("\($0) ms").tag($0) }
                    }
                    .labelsHidden()
                }
            }
            .disabled(model.active)
            HStack {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .accessibilityHidden(true)
                Slider(value: $model.volume, in: 0...1).accessibilityLabel("播放音量")
                Text("\(Int(model.volume * 100))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(secondary)
                    .frame(width: 39, alignment: .trailing)
            }
        }
    }

    private var statusPanel: some View {
        card {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(model.phase.label).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(model.backend == .bluez ? "48 kHz · 双声道 · SBC 经 SSH" : "48 kHz · 双声道 · PCM 经 SSH")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(secondary)
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .textSelection(.enabled)
            }
            HStack(alignment: .center, spacing: 12) {
                metric("Mac 排队", model.metrics.map { "\(Int($0.appBufferMs.rounded())) ms" } ?? "—")
                    .help("音频在 Mac 应用和 Audio Queue 中的排队量，不含 Switch 与蓝牙段。")
                metric("缓冲不足", model.metrics.map { "\($0.underruns) 次" } ?? "—")
                metric("丢弃旧音频", model.metrics.map { "\(Int(Double($0.droppedFrames) / 48)) ms" } ?? "—")
                VStack(alignment: .leading, spacing: 8) {
                    Text("输出电平").font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                    HStack(spacing: 3) {
                        let level = model.metrics.map { min(1, max(0, (20 * log10(max(0.001, $0.level)) + 60) / 60)) } ?? 0
                        ForEach(0..<15) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Double(index + 1) / 15 <= level ? mint.opacity(0.92) : Color.white.opacity(0.09))
                                .frame(height: 14)
                        }
                    }
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .playing: mint
        case .connecting, .buffering: .yellow
        case .error: .orange
        case .disconnected: secondary
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
    }

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            .padding(.bottom, 4)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.75).contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(field, in: RoundedRectangle(cornerRadius: 8))
    }

    private func card<Contents: View>(@ViewBuilder _ content: () -> Contents) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.07)) }
    }
}
