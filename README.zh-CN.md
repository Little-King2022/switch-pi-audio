# Switch Pi Audio

[English](README.md) · [OpenWrt 安装步骤（英文）](docs/openwrt.md) · [延迟实测](docs/measurements.md)

把任天堂 Switch 的游戏声音送到 Mac 扬声器。树莓派用板载蓝牙充当 A2DP 音箱，再用现有 SSH 连接把音频传给 macOS 原生播放器。Mac 和树莓派可在同一个局域网内连接。

![Switch 音频 App 的缓冲曲线和播放设置](docs/mac-app.png)

*截图使用原生 App 回放一段真实的播放监控数据。*

- **PulseAudio（默认）**由树莓派解码，发送 48 kHz 双声道 16 位 PCM。
- **BlueZ 直读（实验）**由树莓派读取 SBC 帧，经 SSH 发送到 Mac 解码。
- 两种模式共用 Core Audio 播放器。App 显示最近 60 秒的接收速率、Mac 排队量、PCM 电平、缓冲不足和旧音频丢弃。

## 使用

已验证树莓派 4B（ImmortalWrt 24.10.1，ARM64）、Switch 2 和 Apple Silicon Mac。App 需要 macOS 14 或更高版本。建议从 **80 ms** 目标缓冲开始。

1. 按 [OpenWrt 安装步骤](docs/openwrt.md) 构建并安装树莓派服务，配置 Switch 的蓝牙地址，并确认 Mac 可通过 SSH 密钥登录。把下列示例中的 `pi-audio` 换成自己的 SSH 别名。
2. 在 Mac 安装 Xcode 命令行工具（如有需要运行 `xcode-select --install`）并构建 App。

   ```sh
   git clone https://github.com/Little-King2022/switch-pi-audio.git
   cd switch-pi-audio
   ./macOS/build.sh
   open "macOS/build/Switch 音频.app"
   ```

3. 在 Switch 打开「设置 → 蓝牙音频」，连接 `Switch-Pi-Audio` 并播放游戏声音。
4. 在 App 填写 SSH 地址，选择后端、播放设备和缓冲，然后点「连接」。只有一路蓝牙输入时，PulseAudio 输入可留空。

切换后端时先断开 App，选中目标后端并点「切换树莓派后端」，然后在 Switch 重连，最后在 App 恢复播放。也可以用 `ssh pi-audio /usr/libexec/switch-audio-backend bluez` 开启直读，或用 `ssh pi-audio /usr/libexec/switch-audio-backend pulse` 回退。树莓派重启后默认使用 PulseAudio。

## 参与贡献

欢迎提交 Issue 或 PR。排查音频问题时，可以附上固件版本、正在用的后端、缓冲参数和 App 的监控数据。公开分享日志前请去掉设备地址和密钥。

本项目采用 [Apache-2.0](LICENSE)。内置 SBC 解码器的来源和声明见 [Decoder](macOS/Decoder/SOURCE.md)。
