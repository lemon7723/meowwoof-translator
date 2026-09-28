# -*- coding: utf-8 -*-
"""临时：候选源画像（纯串行、轻量）"""
import os
import subprocess
import sys

import numpy as np

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
RAW3 = os.path.join(HERE, "..", "_sfx_raw3")
RAW2 = os.path.join(HERE, "..", "_sfx_raw2")

CAT = ["meow_732521", "foodmeow_650417", "foodmeow_843100",
       "kitten2_735643", "kitten2_424357", "meow_hungry_want"]
DOG = ["dogmurmur_237193", "dogmurmur_822917", "sigh_427172", "sigh_840806",
       "sigh_853452", "yawn_423490", "yawn_827660", "whine2_825485",
       "whine2_461527", "puppy_350593", "puppy_31243", "whine_505827",
       "whine_455745", "whine_417144", "whine_461526"]


def profile(name):
    src = None
    for base in (RAW3, RAW2):
        p = os.path.join(base, name + ".wav")
        if os.path.exists(p):
            src = p
            break
    if src is None:
        return "%-18s MISSING" % name
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", src, "-f", "f32le", "-ac", "1",
         "-ar", str(SR), "-"],
        capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).copy()
    pk = float(np.max(np.abs(x)))
    if pk > 0:
        x = x / pk
    fl = int(0.025 * SR)
    nf = len(x) // fl
    rms = np.sqrt((x[:nf * fl].reshape(nf, fl) ** 2).mean(axis=1))
    floor = float(np.percentile(rms, 10))
    snr = 20 * np.log10(
        (float(np.percentile(rms, 90)) + 1e-9) / (floor + 1e-9))
    act = rms > max(floor * 3, 0.05)
    idx = np.where(act)[0]
    if len(idx) == 0:
        return "%-18s no-active-frames" % name
    seg = x[idx[0] * fl: min(len(x), (idx[-1] + 1) * fl)]
    step = max(1, len(seg) // 200000)  # 防超长
    seg = seg[::step]
    S = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    fr = np.fft.rfftfreq(len(seg), 1 / SR)
    cent = float((S * fr).sum() / (S.sum() + 1e-9))
    spans = []
    i = 0
    while i < nf:
        if act[i]:
            j = i
            while j < nf and act[j]:
                j += 1
            if (j - i) * 0.025 >= 0.18:
                spans.append("%.2f-%.2f" % (i * 0.025, j * 0.025))
            i = j
        else:
            i += 1
    return "%-18s dur=%5.2f SNR=%6.1f cent=%5.0f  %s" % (
        name, len(x) / SR, snr, cent, " ".join(spans[:6]))


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else "all"
    names = (CAT if only in ("all", "cat") else []) + \
            (DOG if only in ("all", "dog") else [])
    for n in names:
        print(profile(n), flush=True)


if __name__ == "__main__":
    main()
