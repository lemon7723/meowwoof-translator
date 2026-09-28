# -*- coding: utf-8 -*-
"""第二轮候选素材体检：时长/信噪比/音节结构，人工读数后选剪辑点"""
import os
import subprocess

import numpy as np

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "..", "_sfx_raw3")

CANDS = [
    "foodmeow_843100", "foodmeow_120160", "foodmeow_650417",
    "sigh_427172", "yawn_826022", "yawn_827660", "yawn_423490",
]


def decode(name):
    p = os.path.join(RAW, name + ".wav")
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", p, "-f", "f32le", "-ac", "1",
         "-ar", str(SR), "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).copy()
    return x / max(float(np.max(np.abs(x))), 1e-9)


def snr_db(x):
    fl = int(0.025 * SR)
    nf = max(1, len(x) // fl)
    rms = np.sqrt((x[:nf * fl].reshape(nf, fl) ** 2).mean(axis=1))
    return 20 * np.log10((np.percentile(rms, 90) + 1e-9) /
                         (np.percentile(rms, 10) + 1e-9))


for name in CANDS:
    try:
        x = decode(name)
    except Exception as e:
        print(name, "MISSING", e)
        continue
    dur = len(x) / SR
    fl = int(0.010 * SR)
    nf = len(x) // fl
    rms = np.sqrt((x[:nf * fl].reshape(nf, fl) ** 2).mean(axis=1))
    th = max(float(np.percentile(rms, 60)), 0.05)
    above = rms > th
    segs = []
    i = 0
    while i < nf:
        if above[i]:
            j = i
            while j < nf and above[j]:
                j += 1
            if (j - i) * 0.010 >= 0.12:
                segs.append((i * 0.010, j * 0.010))
            i = j
        else:
            i += 1
    print("%-18s dur=%5.2fs SNR=%5.1fdB segs=%d" % (name, dur, snr_db(x), len(segs)))
    for a, b in segs[:8]:
        seg = x[int(a * SR):int(b * SR)]
        S = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
        fr = np.fft.rfftfreq(len(seg), 1 / SR)
        cent = float((S * fr).sum() / (S.sum() + 1e-9))
        print("    %.2f-%.2fs (%.2fs) cent=%4.0fHz" % (a, b, b - a, cent))
