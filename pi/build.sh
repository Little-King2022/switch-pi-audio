#!/bin/sh
set -eu
cd "$(dirname "$0")"
root="$PWD/build/root"
mkdir -p "$root/usr/libexec" "$root/etc/init.d" "$root/etc/pulse/system.pa.d" "$root/usr/share/switch-pi-audio"
(cd discovery && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "$root/usr/libexec/switch-audio-discovery" .)
(cd sbc && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "$root/usr/libexec/switch-audio-sbc" .)
install -m 0755 openwrt/switch-audio-backend openwrt/switch-audio-hciattach "$root/usr/libexec/"
install -m 0755 openwrt/switch-audio-discovery openwrt/switch-audio-uart openwrt/switch-audio-sbc "$root/etc/init.d/"
install -m 0644 openwrt/90-switch-audio.pa "$root/etc/pulse/system.pa.d/"
install -m 0644 openwrt/switch-audio.config.example "$root/usr/share/switch-pi-audio/"
tar -C "$root" -czf build/switch-pi-audio-linux-arm64.tar.gz .
printf '%s\n' "$PWD/build/switch-pi-audio-linux-arm64.tar.gz"
