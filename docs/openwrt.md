# Install on OpenWrt or ImmortalWrt

These steps are based on a Raspberry Pi 4B running the 64-bit ImmortalWrt 24.10.1 `bcm27xx/bcm2711` image. The direct backend expects `hci0`. Kernel modules and package names must match your installed firmware and feeds. Run device-side commands as root.

## 1. Confirm the onboard radio

On the Pi, install the BlueZ and PulseAudio packages for your image. These were used on the tested release.

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

The `-avahi` package variant provides PulseAudio with BlueZ support on the tested image. Confirm the presence of `module-bluetooth-discover.so` with `opkg files pulseaudio-daemon-avahi`. The backend selector also uses `flock`, which was provided by BusyBox on this image. [OpenWrt package definition](https://github.com/openwrt/packages/blob/openwrt-24.10/sound/pulseaudio/Makefile)

If the firmware already presents the onboard Bluetooth controller as `hci0`, continue to the next section. If `bluetoothctl list` is empty on a Pi 4, check the boot configuration and `logread`.

- Back up `/boot/distroconfig.txt`. On the tested image, its `[pi4]` block had `dtoverlay=disable-bt`. Replacing that line with `dtparam=krnbt=on` enabled the Bluetooth device tree node. Keep the other board sections and settings as supplied. [OpenWrt image configuration](https://github.com/openwrt/openwrt/blob/openwrt-24.10/target/linux/bcm27xx/image/distroconfig.txt)
- If the onboard BCM4345C0 radio needs firmware, use your distribution's package, or obtain the [BCM4345C0 firmware file from Raspberry Pi](https://github.com/RPi-Distro/bluez-firmware/blob/master/broadcom/BCM4345C0.hcd) and put it at `/lib/firmware/brcm/BCM4345C0.hcd` on the Pi.
- After installing the project files in the next step, enable `/etc/init.d/switch-audio-uart` and reboot if the onboard UART is present but a kernel driver still fails to attach the controller. This fallback uses `hciattach` from `bluez-utils-extra` and the Pi 4 device-tree alias to find the radio. It exits immediately when `hci0` already exists. A reboot is required for boot configuration changes to take effect.

## 2. Build and copy the Pi services

Use Go 1.24 or later on your build machine. Set up a verified, key-based SSH alias named `pi-audio` pointing to the Pi's root account, or substitute your own alias in these commands.

```sh
./pi/build.sh
tar -tzf pi/build/switch-pi-audio-linux-arm64.tar.gz
ssh -o BatchMode=yes pi-audio 'tar -xozf - -C /' < pi/build/switch-pi-audio-linux-arm64.tar.gz
```

The archive contains the two ARM64 binaries, the launcher scripts, and the PulseAudio config fragment. The example UCI configuration is installed under `/usr/share/switch-pi-audio`. The archive preserves your live `/etc/config/switch-audio` and Bluetooth pairing database.

## 3. Configure PulseAudio

On the Pi, back up `/etc/pulse/system.pa` and `/etc/init.d/pulseaudio` before editing. These settings use PulseAudio's system instance.

- Make sure the active configuration loads `module-bluetooth-discover` once. The installed `90-switch-audio.pa` fragment does this when `system.pa` includes `.include /etc/pulse/system.pa.d`.
- Use `load-module module-native-protocol-unix auth-group=root` for the local PulseAudio socket on the dedicated receiver. Keep existing authentication and socket settings if you already have a compatible root-only connection at `/var/run/pulse/native`. The setup uses no PulseAudio TCP listener.
- If the init script passes `--disallow-module-loading`, remove that flag on this dedicated receiver so the BlueZ module can load the per-device input after pairing. Leave `--system`, `--disallow-exit`, and the other existing arguments as appropriate for the firmware.

```sh
/etc/init.d/pulseaudio enable
/etc/init.d/pulseaudio restart
/usr/libexec/switch-audio-backend status
bluetoothctl show
```

Expect `pulse` and the Audio Sink UUID (`0000110b-0000-1000-8000-00805f9b34fb`). If the socket path differs, change `PULSE_SERVER` in both `pi/openwrt/switch-audio-backend` and the Mac app's SSH command before building.

## 4. Enable discoverability for your console

The discovery agent accepts pairing and audio service authorization for one configured Bluetooth device. Existing, pre-authorized devices in BlueZ retain their own permissions.

If you don't know the console's Bluetooth address, set the controller alias with `bluetoothctl system-alias Switch-Pi-Audio`, make it temporarily discoverable with `bluetoothctl discoverable on`, and attempt to connect from the console's Bluetooth Audio menu. On the Pi, check `bluetoothctl devices`. If the temporary device object disappears, install `bluez-utils-btmon` and watch the source address of the **Connect Request** emitted during the attempt. Turn off temporary discoverability after identifying the device.

Copy the example on first install, replace the placeholder with the console's address, then enable the discovery service.

```sh
test -f /etc/config/switch-audio || \
  cp /usr/share/switch-pi-audio/switch-audio.config.example /etc/config/switch-audio
vi /etc/config/switch-audio
/etc/init.d/switch-audio-discovery enable
/etc/init.d/switch-audio-discovery restart
```

Connect to `Switch-Pi-Audio` from the Switch and play audio. For the PulseAudio mode, check that `PULSE_SERVER=unix:/var/run/pulse/native pactl list short sources` reports a BlueZ source. For experimental direct mode, check `logread -e switch-audio-sbc` for an endpoint registration and successful SBC negotiation. After a backend switch, reconnect from the console. To turn off continuous discovery, stop and disable `switch-audio-discovery`.

## Restore or diagnose

- `/usr/libexec/switch-audio-backend pulse` restores PulseAudio. Its startup service remains enabled for boot. Keep the experimental `switch-audio-sbc` service disabled at boot.
- `bluetoothctl show` reports the alias, discoverability, and Audio Sink UUID. `logread -e switch-audio-discovery` shows whether the discovery service is still waiting for the controller or the endpoint.
- Check SSH host verification and key login in Terminal first. The macOS app uses `BatchMode=yes` and cannot answer interactive SSH prompts.
