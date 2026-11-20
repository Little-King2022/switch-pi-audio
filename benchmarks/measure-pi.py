#!/usr/bin/env python3
"""Measure live Switch SBC and the corresponding local SSH producer on one Pi clock."""

import ctypes
import os
import re
import selectors
import socket
import struct
import subprocess
import sys
import time

mode, seconds = sys.argv[1], float(sys.argv[2])
if mode not in ("pulse", "bluez") or not 2 <= seconds <= 35:
    raise SystemExit("usage: measure-pi.py pulse|bluez SECONDS")

# Linux Bluetooth monitor channel. We emit only A2DP SBC media payloads,
# never HCI commands, pairing events, or any other traffic.
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.socket(31, 3 | socket.SOCK_CLOEXEC, 1)
if fd < 0:
    raise OSError(ctypes.get_errno(), "HCI monitor socket")
addr = struct.pack("=HHH", 31, 0xffff, 2)
if libc.bind(fd, addr, len(addr)) < 0:
    raise OSError(ctypes.get_errno(), "bind HCI monitor channel")
monitor = socket.socket(fileno=fd, family=31, type=3, proto=1)
monitor.setsockopt(socket.SOL_SOCKET, 35, 1)  # SO_TIMESTAMPNS_OLD on arm64 Linux
monitor.setblocking(False)
pending = {}


def sbc_payload(data):
    if len(data) < 17 or data[0] != 0x80 or data[12] < 1 or data[12] > 15:
        return None
    payload = data[13:]
    offset = 0
    for _ in range(data[12]):
        if offset + 4 > len(payload):
            return None
        sync, fmt, bitpool = payload[offset:offset+3]
        mode = (fmt >> 2) & 3
        if sync != 0x9c or fmt & 0xf1 != 0xf1 or mode < 2 or not 2 <= bitpool <= 53:
            return None
        offset += 12 + 2 * bitpool + (mode == 3)
    if offset == len(payload):
        return payload


def hci_packet(data):
    if len(data) < 10 or data[:4] != b"\x05\x00\x00\x00":
        return None
    flags, size = struct.unpack_from("<HH", data, 6)
    if size + 10 != len(data):
        return None
    handle = flags & 0xfff
    if (flags >> 12) & 3 == 1:
        old = pending.pop(handle, None)
        if old is None:
            return None
        needed, prefix = old
        body = prefix + data[10:]
    else:
        if size < 4:
            return None
        needed, cid = struct.unpack_from("<HH", data, 10)
        if cid < 0x40 or needed < 17 or needed > 2000:
            return None
        body = data[14:]
    if len(body) < needed:
        pending[handle] = needed, body
        return None
    if len(body) == needed:
        return sbc_payload(body)


def emit(kind, now, payload):
    sys.stdout.buffer.write(struct.pack("<BQI", kind, now, len(payload)) + payload)


if mode == "pulse":
    os.environ["PULSE_SERVER"] = "unix:/var/run/pulse/native"
    names = subprocess.check_output(["pactl", "list", "short", "sources"], text=True)
    devices = re.findall(r"^\d+\s+(bluez_\S+)\s", names, re.M)
    if len(devices) != 1:
        raise SystemExit("expected a single connected A2DP source")
    command = ["parec", "--raw", "--device=" + devices[0], "--format=s16le", "--rate=48000", "--channels=2"]
else:
    command = ["/usr/libexec/switch-audio-sbc", "--read"]

with subprocess.Popen(command, stdout=subprocess.PIPE) as producer, selectors.DefaultSelector() as selector:
    selector.register(monitor, selectors.EVENT_READ, "hci")
    selector.register(producer.stdout, selectors.EVENT_READ, "producer")
    deadline = time.monotonic() + seconds
    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(0.25):
                if key.data == "producer":
                    data = os.read(key.fd, 65536)
                    if not data:
                        raise SystemExit("producer closed")
                    emit(2, time.time_ns(), data)
                    continue
                packet, ancillary, _, _ = monitor.recvmsg(4096, 64)
                payload = hci_packet(packet)
                if payload:
                    for level, kind, stamp in ancillary:
                        if level == socket.SOL_SOCKET and kind == 35:
                            sec, nsec = struct.unpack("=qq", stamp)
                            emit(1, sec * 10**9 + nsec, payload)
                            break
    finally:
        producer.terminate()
