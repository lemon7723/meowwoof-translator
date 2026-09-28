# -*- coding: utf-8 -*-
"""对用户提供的 9 条素材做声学画像，确定与 10 意图的映射"""
import os
import subprocess
import sys

import numpy as np

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, "..", "..", "_ref_frames")

FILES = ["mine_cat_happy", "mine_soundreality-cat-meow-fx-461188",
         "mine_sound_garage-cat-meow-8-fx-306184",
         "mine_domestic-cat-meowing", "mine_cute-purr", "mine_purring-cat",
         "mine_cat_stop", "mine_angry-aggressive-cat",
         "mine_nasty-meowing-of-a-cat-during-the-mating-season"]


def profile(name):
    src = os.path.join(D, name + ".wav")
    if not os.path.exists(src):
        return "%-46s MISSING" % name
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
    act = rms > max(floor * 3, 0.04)
    idx = np.where(act)[0]
    if len(idx) == 0:
        return "%-46s silent" % name
    # 最长活跃段与总活跃时长
    spans = []
    i = 0
    while i < nf:
        if act[i]:
            j = i
            while j < nf and act[j]:
                j += 1
            if (j - i) * 0.025 >= 0.15:
                spans.append((i * 0.025, j * 0.025))
            i = j
        else:
            i += 1
    best = max(spans, key=lambda s: s[1] - s[0]) if spans else (0, 0)
    # 长段的频谱质心 + 波动（咕噜是低频稳态脉冲）
    seg = x[int(best[0] * SR):int(best[1] * SR)]
    if len(seg) > SR:
        seg = seg[:SR]
    S = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    fr = np.fft.rfftfreq(len(seg), 1 / SR)
    cent = float((S * fr).sum() / (S.sum() + 1e-9))
    # 低频占比（<500Hz）——咕噜特征
    lf = float(S[fr < 500].sum() / (S.sum() + 1e-9))
    return ("%-46s dur=%5.2f SNR=%5.1f cent=%5.0f LF%%=%4.2f best=%.2f-%.2f "
            "spans=%d" % (name, len(x) / SR, snr, cent, lf, best[0], best[1],
                          len(spans)))


for n in FILES:
    print(profile(n), flush=True)
