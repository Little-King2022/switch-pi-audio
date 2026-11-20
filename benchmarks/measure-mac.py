#!/usr/bin/env python3
"""Compare one remote capture in RAM. Output only timing/fit aggregates."""

import argparse
import json
from pathlib import Path
import struct
import subprocess
import sys

import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", choices=["pulse", "bluez"])
parser.add_argument("--host", required=True, help="SSH alias or user@host")
parser.add_argument("--seconds", type=int, choices=range(2, 36), default=15, metavar="2..35")
parser.add_argument("--ffmpeg", default="ffmpeg")
args = parser.parse_args()
mode = args.mode
with Path(__file__).with_name("measure-pi.py").open("rb") as script:
    capture = subprocess.check_output(
        ["ssh", "-o", "BatchMode=yes", "--", args.host, "python3", "-", mode, str(args.seconds)],
        stdin=script,
    )


def decode(sbc):
    pcm = subprocess.check_output(
        [args.ffmpeg, "-v", "error", "-f", "sbc", "-i", "pipe:0", "-f", "s16le", "pipe:1"],
        input=sbc,
    )
    return signal(pcm)


def signal(data):
    return np.frombuffer(data, dtype="<i2").reshape(-1, 2)[:, 0].astype(np.float64)


def sbc_samples(data):
    count = 0
    start = 0
    while start + 4 <= len(data):
        assert data[start] == 0x9c
        start += 12 + 2 * data[start+2] + (((data[start+1] >> 2) & 3) == 3)
        if start <= len(data):
            count += 128
    return count


def joined(chunks):
    return b"".join(payload for _, payload in chunks)


def positions(chunks, compressed):
    stamps, ends = [], []
    size = 0
    data = joined(chunks)
    for t, part in chunks:
        before, size = size, size + len(part)
        if compressed:
            count = sbc_samples(data[before:size])
        else:
            count = (size // 4) - (before // 4)
        if count:
            ends.append((ends[-1] if ends else 0) + count)
            stamps.append(t)
    return np.array(stamps, dtype=np.int64), np.array(ends, dtype=np.int64)


def result(delays, **extra):
    delays = np.array(delays) / 1e6
    if len(delays) < 10:
        raise SystemExit("not enough matching audio samples")
    print(json.dumps(dict(mode=mode, samples=len(delays),
        p10_ms=round(float(np.percentile(delays, 10)), 2),
        p50_ms=round(float(np.median(delays)), 2),
        p90_ms=round(float(np.percentile(delays, 90)), 2), **extra)))


chunks = {1: [], 2: []}
offset = 0
while offset < len(capture):
    kind, stamp, size = struct.unpack_from("<BQI", capture, offset)
    offset += 13
    chunks[kind].append((stamp, capture[offset:offset+size]))
    offset += size
print(f"records: HCI {len(chunks[1])}, producer {len(chunks[2])}", file=sys.stderr)
ref_stamps, ref_ends = positions(chunks[1], True)
if mode == "bluez":
    ref = joined(chunks[1])
    ref_byte_ends = np.cumsum([len(part) for _, part in chunks[1]])
    delays = []
    for out_stamp, part in chunks[2]:
        # Verify exact SBC bytes. Coalesced/partially read packets are counted
        # at the producer read carrying their final byte.
        if len(part) < 8:
            continue
        start = ref.find(part)
        if start < 0 or ref.find(part, start+1) >= 0:
            continue
        index = ref_byte_ends.searchsorted(start+len(part)-1, side="right")
        if index < len(ref_stamps) and 0 <= out_stamp-ref_stamps[index] < 2e9:
            delays.append(out_stamp-ref_stamps[index])
    result(delays, method="exact SBC byte match")
else:
    reference = decode(joined(chunks[1]))
    candidate = signal(joined(chunks[2]))
    out_stamps, out_ends = positions(chunks[2], False)
    delays, fits = [], []
    for index in range(4, len(ref_stamps)-5, 3):
        time = ref_stamps[index]
        end = ref_ends[index]
        length = 900
        if end > len(reference) or end < length:
            continue
        template = reference[end-length:end]
        template = template - template.mean()
        energy = np.dot(template, template)
        if energy < 1e6:
            continue
        start_i = out_stamps.searchsorted(time - 250_000_000)
        if start_i >= len(out_stamps):
            continue
        stop_i = min(len(out_ends) - 1, out_stamps.searchsorted(time + 350_000_000))
        start = max(0, out_ends[start_i]-length-3000)
        stop = min(len(candidate), out_ends[stop_i])
        region = candidate[start:stop]
        if len(region) < length:
            continue
        divisor = np.sqrt(np.maximum(1, np.r_[0, np.cumsum(region * region)][length:] -
            np.r_[0, np.cumsum(region * region)][:-length]) * energy)
        rho = np.correlate(region, template, "valid") / divisor
        pos = int(rho.argmax())
        fit = rho[pos]
        if fit < 0.82:
            continue
        matched = start + pos + length - 1
        match_i = out_ends.searchsorted(matched, side="right")
        if match_i < len(out_stamps) and 0 <= out_stamps[match_i] - time < 300e6:
            delays.append(out_stamps[match_i] - time)
            fits.append(fit)
    result(delays, method="decoded PCM waveform match", median_fit=round(float(np.median(fits)), 3))
