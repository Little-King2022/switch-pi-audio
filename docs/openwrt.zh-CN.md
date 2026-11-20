# 在 OpenWrt 或 ImmortalWrt 上安装

[English](openwrt.md) · [项目首页](../README.zh-CN.md)

以下步骤基于运行 64 位 ImmortalWrt 24.10.1（`bcm27xx/bcm2711`）的树莓派 4B。BlueZ 直读后端需要 `hci0`。内核模块和软件包必须与当前固件及软件源匹配。树莓派端命令以 root 身份执行。

## 1. 确认板载蓝牙可用

在树莓派上安装适用于当前镜像的 BlueZ 和 PulseAudio。测试镜像使用了以下软件包：

```sh
opkg update
opkg install kmod-bluetooth dbus bluez-daemon bluez-utils bluez-utils-extra \
  pulseaudio-daemon-avahi pulseaudio-profiles pulseaudio-tools
/etc/init.d/dbus enable
/etc/init.d/dbus start
/etc/init.d/bluetoothd enable
/etc/init.d/bluetoothd start
bluetoothctl list
```

在测试镜像上，`-avahi` 变体提供支持 BlueZ 的 PulseAudio。运行 `opkg files pulseaudio-daemon-avahi`，确认包含 `module-bluetooth-discover.so`。后端切换器还依赖 `flock`，该镜像由 BusyBox 提供。[OpenWrt 软件包定义](https://github.com/openwrt/packages/blob/openwrt-24.10/sound/pulseaudio/Makefile)

如果系统已把板载蓝牙识别为 `hci0`，直接进入下一节。如果树莓派 4 上 `bluetoothctl list` 没有输出，检查启动配置和 `logread`：

- 先备份 `/boot/distroconfig.txt`。测试镜像的 `[pi4]` 段含有 `dtoverlay=disable-bt`，将这一行替换为 `dtparam=krnbt=on` 后，设备树中的蓝牙节点会启用。保留其他板型的配置段和设置。[OpenWrt 镜像配置](https://github.com/openwrt/openwrt/blob/openwrt-24.10/target/linux/bcm27xx/image/distroconfig.txt)
- 如果板载 BCM4345C0 需要额外固件，使用发行版提供的软件包，或将 [Raspberry Pi 提供的 BCM4345C0 固件](https://github.com/RPi-Distro/bluez-firmware/blob/master/broadcom/BCM4345C0.hcd) 放到树莓派的 `/lib/firmware/brcm/BCM4345C0.hcd`。
- 安装下一节中的项目文件后，如果板载 UART 已出现但内核驱动仍未挂载蓝牙控制器，启用 `/etc/init.d/switch-audio-uart` 后重启。该备用服务使用 `bluez-utils-extra` 提供的 `hciattach` 和树莓派 4 的设备树别名定位控制器。若 `hci0` 已存在，则直接退出。启动配置改动需要重启才能生效。

## 2. 构建并安装树莓派服务

在构建机器上使用 Go 1.24 或更高版本。设置名为 `pi-audio` 的 SSH 别名，使用密钥登录树莓派的 root 账户，并事先核验主机密钥。也可把以下命令中的 `pi-audio` 换成自己的别名。

```sh
./pi/build.sh
tar -tzf pi/build/switch-pi-audio-linux-arm64.tar.gz
ssh -o BatchMode=yes pi-audio 'tar -xozf - -C /' < pi/build/switch-pi-audio-linux-arm64.tar.gz
```

压缩包包含两个 ARM64 二进制文件、启动脚本和 PulseAudio 配置片段。UCI 示例配置安装在 `/usr/share/switch-pi-audio`。解包不会覆盖现有的 `/etc/config/switch-audio` 或蓝牙配对数据库。

## 3. 配置 PulseAudio

在树莓派上编辑前先备份 `/etc/pulse/system.pa` 和 `/etc/init.d/pulseaudio`。以下设置针对 PulseAudio 系统实例：

- 确保当前配置只加载一次 `module-bluetooth-discover`。如果 `system.pa` 已包含 `.include /etc/pulse/system.pa.d`，安装的 `90-switch-audio.pa` 就会加载该模块。
- 在专用接收设备上使用 `load-module module-native-protocol-unix auth-group=root` 配置本地套接字。如果 `/var/run/pulse/native` 已提供兼容且仅限 root 的连接，请保留现有认证和套接字配置。本方案不需要 PulseAudio TCP 监听端口。
- 如果初始化脚本使用了 `--disallow-module-loading`，可在这台专用接收设备上移除该参数，让 BlueZ 模块在配对后加载该设备的音频输入。按固件要求保留 `--system`、`--disallow-exit` 及其他原有参数。

```sh
/etc/init.d/pulseaudio enable
/etc/init.d/pulseaudio restart
/usr/libexec/switch-audio-backend status
bluetoothctl show
```

预期看到 `pulse` 和 Audio Sink UUID（`0000110b-0000-1000-8000-00805f9b34fb`）。如果套接字路径不同，请在构建前同时修改 `pi/openwrt/switch-audio-backend` 和 Mac App 的 SSH 命令中的 `PULSE_SERVER`。

## 4. 让 Switch 发现接收设备

发现服务仅为配置中的一台蓝牙设备接受配对请求并授权音频服务。此前已在 BlueZ 中获授权的设备不受影响。

如果不知道 Switch 的蓝牙地址，先执行 `bluetoothctl system-alias Switch-Pi-Audio` 设置控制器名称，再用 `bluetoothctl discoverable on` 临时开启可发现模式，之后从 Switch 的蓝牙音频菜单尝试连接。在树莓派上运行 `bluetoothctl devices` 查看地址。如果临时设备条目消失，安装 `bluez-utils-btmon`，再次连接时观察 **Connect Request** 的源地址。确认地址后关闭临时可发现模式。

首次安装时复制示例配置，把占位符替换成 Switch 的蓝牙地址，然后启用发现服务：

```sh
test -f /etc/config/switch-audio || \
  cp /usr/share/switch-pi-audio/switch-audio.config.example /etc/config/switch-audio
vi /etc/config/switch-audio
/etc/init.d/switch-audio-discovery enable
/etc/init.d/switch-audio-discovery restart
```

在 Switch 上连接 `Switch-Pi-Audio` 并播放音频。使用 PulseAudio 时，运行 `PULSE_SERVER=unix:/var/run/pulse/native pactl list short sources`，确认出现 BlueZ 音源。使用实验性直读后端时，用 `logread -e switch-audio-sbc` 检查端点注册和 SBC 协商是否成功。每次切换后端后，需要在 Switch 上重新连接。若不再需要持续发现，可停止并禁用 `switch-audio-discovery`。

## 恢复与排查

- 运行 `/usr/libexec/switch-audio-backend pulse` 恢复 PulseAudio。它的启动服务保留为开机启动，实验性的 `switch-audio-sbc` 保持不开机启动。
- `bluetoothctl show` 可查看控制器名称、可发现状态和 Audio Sink UUID。`logread -e switch-audio-discovery` 可检查发现服务是否还在等待控制器或端点。
- 先在终端检查 SSH 主机验证与密钥登录。macOS App 使用 `BatchMode=yes`，无法回答交互式 SSH 提示。
