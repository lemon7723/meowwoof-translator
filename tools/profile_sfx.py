#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""素材声学画像：时长/F0估计/频谱质心/能量分布，用于客观分型选材"""
import os

import numpy as np

D = os.path.join(os.path.dirname(__file__), "..", "_sfx_raw2")
SR = 22050

def frames(x, n=1024, hop=512):
    for i in range(0, len(x) - n, hop):
        yield x[i:i + n]

def f0_autocorr(x, sr=SR, fmin=50, fmax=2000):
    """中位基频估计（对有声帧）"""
    f0s = []
    thr = np.max(np.abs(x)) * 0.15 if len(x) else 0
    for fr in frames(x):
        if np.sqrt(np.mean(fr ** 2)) < thr:
            continue
        r = np.correlate(fr, fr, mode="full")[len(fr) - 1:]
        if r[0] <= 0:
            continue
        r = r / r[0]
        lo, hi = int(sr / fmax), min(int(sr / fmin), len(r) - 1)
        if hi <= lo:
            continue
        lag = lo + int(np.argmax(r[lo:hi]))
        if r[lag] > 0.5:
            f0s.append(sr / lag)
    return float(np.median(f0s)) if f0s else 0.0

def analyze(name):
    import wave
    with wave.open(os.path.join(D, name)) as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    if sr != SR:
        return None
    dur = len(x) / SR
    f0 = f0_autocorr(x)
    sp = np.abs(np.fft.rfft(x))
    fr = np.fft.rfftfreq(len(x), 1 / SR)
    cent = float((sp * fr).sum() / max(sp.sum(), 1e-9))
    # 能量分布：<500Hz / 500-2k / >2k
    e1 = float(sp[fr < 500].sum() / sp.sum())
    e2 = float(sp[(fr >= 500) & (fr < 2000)].sum() / sp.sum())
    e3 = float(sp[fr >= 2000].sum() / sp.sum())
    peak = float(np.abs(x).max())
    return dur, f0, cent, e1, e2, e3, peak

def main():
    files = sorted(f for f in os.listdir(D) if f.endswith(".wav"))
    print(f"{'file':<28}{'dur':>6}{'F0':>7}{'cent':>7}{'<500':>7}{'0.5-2k':>8}{'>2k':>7}")
    for f in files:
        r = analyze(f)
        if r is None:
            print(f"{f:<28}  (sr mismatch)")
            continue
        dur, f0, cent, e1, e2, e3, peak = r
        print(f"{f:<28}{dur:>6.2f}{f0:>7.0f}{cent:>7.0f}{e1:>7.2f}{e2:>8.2f}{e3:>7.2f}")

if __name__ == "__main__":
    main()
