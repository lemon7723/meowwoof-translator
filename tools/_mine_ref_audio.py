# -*- coding: utf-8 -*-
"""从用户提供的参考 App 录屏音轨中分段提取猫声音效。
输出候选片段的声学画像（时长/信噪比/谱质心/基频），供人工确认后入库。"""
import os
import subprocess

import numpy as np

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
# 参考录屏有版权属性：源音频与提取物都放仓库外（工作区根），不进 git
SRC = os.path.join(HERE, "..", "..", "_ref_frames", "ref_audio.wav")
OUT = os.path.join(HERE, "..", "..", "_sfx_raw4")

raw = subprocess.run(
    ["ffmpeg", "-v", "error", "-i", SRC, "-f", "f32le", "-ac", "1",
     "-ar", str(SR), "-"],
    capture_output=True, check=True).stdout
x = np.frombuffer(raw, dtype=np.float32).copy()
x /= max(float(np.max(np.abs(x))), 1e-9)

# ---- 25ms 帧 VAD ----
fl = int(0.025 * SR)
nf = len(x) // fl
rms = np.sqrt((x[:nf * fl].reshape(nf, fl) ** 2).mean(axis=1))
floor = float(np.percentile(rms, 15))
th = max(floor * 6, 0.04)

segments = []
i = 0
while i < nf:
    if rms[i] > th:
        j = i
        while j < nf and rms[j] > floor * 2:
            j += 1
        a, b = max(0, i - 2) * 0.025, min(nf, j + 2) * 0.025
        if b - a >= 0.25:
            segments.append((a, b))
        i = j
    else:
        i += 1

def f0_est(seg):
    """自相关基频估计（80-1200Hz），返回 f0 或 0"""
    s = seg - seg.mean()
    if len(s) < SR // 20:
        return 0.0
    ac = np.correlate(s, s, "full")[len(s) - 1:]
    lo, hi = int(SR / 1200), int(SR / 80)
    if hi >= len(ac):
        return 0.0
    k = int(np.argmax(ac[lo:hi])) + lo
    if ac[k] < 0.3 * (ac[0] + 1e-9):
        return 0.0
    return SR / k

print("time          dur    rms    SNR_dB  centHz  f0Hz   verdict")
for a, b in segments:
    seg = x[int(a * SR):int(b * SR)]
    dur = b - a
    r = float(np.sqrt((seg ** 2).mean()))
    quiet = seg[np.abs(seg) < np.percentile(np.abs(seg), 30)]
    snr = 20 * np.log10((np.percentile(np.abs(seg), 95) + 1e-9) /
                        (np.percentile(np.abs(seg), 10) + 1e-9))
    S = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    fr = np.fft.rfftfreq(len(seg), 1 / SR)
    cent = float((S * fr).sum() / (S.sum() + 1e-9))
    f0 = f0_est(seg)
    # 粗判：f0 300-1100 且质心 800-4000 → 猫声；f0<250 且质心<1800 → 可能语音/广告
    if 250 <= f0 <= 1200 and 600 <= cent <= 4500:
        v = "CAT?"
    elif f0 > 0 and f0 < 250:
        v = "speech/ad?"
    elif cent > 4500:
        v = "hiss/UI?"
    else:
        v = "other"
    print("%5.2f-%5.2f  %4.2f  %5.3f  %6.1f  %6.0f  %5.0f  %s"
          % (a, b, dur, r, snr, cent, f0, v))
