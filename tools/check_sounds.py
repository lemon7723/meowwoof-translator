#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""毛语通 · 叫声音频质量校验：格式 / 时长 / 响度 / 频谱集中度"""
import os
import wave

import numpy as np

D = os.path.join(os.path.dirname(__file__), "..", "assets", "sounds")

def main():
    files = sorted(f for f in os.listdir(D) if f.endswith(".wav"))
    total_kb = sum(os.path.getsize(os.path.join(D, f)) for f in files) / 1024
    print(f"{len(files)} files, total {total_kb:.0f} KB")
    header = f"{'file':<24}{'dur':>6}{'peak':>7}{'rms':>7}{'centHz':>8}"
    print(header)
    bad = []
    for f in files:
        with wave.open(os.path.join(D, f)) as w:
            sr = w.getframerate()
            n = w.getnframes()
            ch = w.getnchannels()
            sw = w.getsampwidth()
            x = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768
        dur = n / sr
        peak = float(np.abs(x).max())
        rms = float(np.sqrt((x ** 2).mean()))
        sp = np.abs(np.fft.rfft(x))
        fr = np.fft.rfftfreq(len(x), 1 / sr)
        cent = float((sp * fr).sum() / max(sp.sum(), 1e-9))
        flag = ""
        if sr != 22050 or ch != 1 or sw != 2:
            flag += " BAD-FMT"
        if peak < 0.5 or rms < 0.03:
            flag += " TOO-QUIET"
        if dur < 0.2 or dur > 3.0:
            flag += " BAD-DUR"
        if flag:
            bad.append(f + flag)
        print(f"{f:<24}{dur:>6.2f}{peak:>7.2f}{rms:>7.2f}{cent:>8.0f}{flag}")
    print("RESULT:", ("FAIL: " + "; ".join(bad)) if bad else "ALL PASS")

if __name__ == "__main__":
    main()
