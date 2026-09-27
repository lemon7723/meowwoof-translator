#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
毛语通 · 真实叫声素材组装器 v2
把 _sfx_raw/ 的 Mixkit 真实录音按 10 意图 × 2 物种组装成 assets/sounds/ 下的
同名 WAV（cat_00_come.wav 等），替换原合成音，Dart/原生层零改动。

段表：每段 (素材名, 素材内起始秒, 取用秒, 速度, 增益, 放置时刻)——全部显式，
     无隐式接续逻辑，可直接阅读每条叫声的"配方"。
"""
import os
import subprocess
import wave

import numpy as np

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "..", "_sfx_raw")
OUT = os.path.join(HERE, "..", "assets", "sounds")
FFMPEG = "ffmpeg"

_cache = {}

def decode(name):
    """解码 _sfx_raw/<name>.mp3 -> np.float32 mono @SR，峰值归一"""
    if name in _cache:
        return _cache[name]
    src = os.path.join(RAW, name + ".mp3")
    cmd = [FFMPEG, "-v", "error", "-i", src, "-f", "f32le", "-ac", "1",
           "-ar", str(SR), "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).copy()
    peak = float(np.max(np.abs(x)))
    if peak > 0:
        x = x / peak
    _cache[name] = x
    return x

def resampled(x, speed):
    """变速变调（重采样语义）：>1 更快更高，<1 更慢更低"""
    if abs(speed - 1.0) < 1e-3:
        return x
    n = max(1, int(len(x) / speed))
    idx = np.clip((np.arange(n) * speed).astype(np.int32), 0, len(x) - 1)
    return x[idx]

def cut(x, start, dur):
    a = int(start * SR)
    b = min(len(x), a + int(dur * SR))
    return x[a:b] if b > a else x[: int(dur * SR)]

def place(canvas, seg, t0, gain, fade=0.008):
    i0 = int(t0 * SR)
    if i0 >= len(canvas):
        return
    seg = seg * gain
    f = max(1, int(fade * SR))
    if len(seg) > 2 * f:
        seg = seg.copy()
        seg[:f] *= np.linspace(0, 1, f)
        seg[-f:] *= np.linspace(1, 0, f)
    i1 = min(len(canvas), i0 + len(seg))
    canvas[i0:i1] += seg[: i1 - i0]

def seg(name, start, dur, speed, gain, at):
    return (name, start, dur, speed, gain, at)

LAYOUT = {
    # ============ 猫 ============
    "cat_00_come.wav": (1.15, [  # 两声上扬呼唤
        seg("cat_attention_meow_95", 0.0, 0.9, 1.00, 1.00, 0.00),
        seg("cat_attention_meow_95", 0.0, 0.9, 1.06, 0.85, 1.15),
    ]),
    "cat_01_praise.wav": (2.00, [  # 咕噜 + 一声甜喵
        seg("cat_long_purr_45", 0.0, 1.25, 1.00, 0.95, 0.00),
        seg("cat_sweet_meow_92", 0.0, 0.65, 1.00, 0.80, 1.35),
    ]),
    "cat_02_scold.wav": (1.80, [  # 两声愤怒喵
        seg("cat_angry_meow_89", 0.0, 0.9, 1.00, 1.00, 0.00),
        seg("cat_angry_meow_89", 0.0, 0.9, 1.00, 0.90, 1.00),
    ]),
    "cat_03_stop.wav": (1.55, [  # 短痛叫 + 愤怒喵（急停）
        seg("cat_pain_meow_91", 0.0, 0.7, 1.00, 1.00, 0.00),
        seg("cat_angry_meow_89", 0.0, 0.8, 1.05, 0.90, 0.80),
    ]),
    "cat_04_eat.wav": (1.95, [  # 饿喵 + 讨要喵
        seg("cat_hungry_meow_86", 0.0, 1.0, 1.00, 1.00, 0.00),
        seg("cat_begging_meow_6", 0.0, 0.9, 1.00, 0.90, 1.05),
    ]),
    "cat_05_play.wav": (1.75, [  # 讨要喵 + 卡通喵（轻快）
        seg("cat_begging_meow_6", 0.0, 0.9, 1.00, 1.00, 0.00),
        seg("cat_cartoon_meow_96", 0.0, 0.75, 1.05, 0.85, 1.00),
    ]),
    "cat_06_walk.wav": (1.80, [  # 短甜喵 + 长呼唤
        seg("cat_sweet_meow_92", 0.0, 0.65, 1.00, 0.90, 0.00),
        seg("cat_attention_meow_95", 0.0, 1.0, 1.00, 1.00, 0.75),
    ]),
    "cat_07_sleep.wav": (1.90, [  # 慢呻吟降速降调（困意）
        seg("cat_slow_moan_88", 0.3, 1.6, 0.85, 0.75, 0.00),
    ]),
    "cat_08_comfort.wav": (1.80, [  # 真实长咕噜
        seg("cat_long_purr_45", 0.0, 1.7, 1.00, 1.00, 0.00),
    ]),
    "cat_09_talk.wav": (1.45, [  # 甜喵 + 卡通喵（友好搭话）
        seg("cat_sweet_meow_92", 0.0, 0.6, 1.05, 0.90, 0.00),
        seg("cat_cartoon_meow_96", 0.0, 0.7, 1.00, 0.85, 0.70),
    ]),
    # ============ 狗 ============
    "dog_00_come.wav": (1.05, [  # 汪汪两声
        seg("dog_bark_twice_60", 0.0, 1.0, 1.00, 1.00, 0.00),
    ]),
    "dog_01_praise.wav": (1.40, [  # 开心幼犬吠
        seg("dog_happy_puppy_59", 0.0, 1.3, 1.00, 1.00, 0.00),
    ]),
    "dog_02_scold.wav": (1.95, [  # 低吼 + 愤怒吠
        seg("dog_growl_angry_467", 0.0, 0.7, 1.00, 1.00, 0.00),
        seg("dog_angry_bark_741", 0.0, 1.2, 1.00, 0.95, 0.75),
    ]),
    "dog_03_stop.wav": (1.40, [  # 烦躁吠（急停）
        seg("dog_annoyed_bark_466", 0.0, 1.3, 1.00, 1.00, 0.00),
    ]),
    "dog_04_eat.wav": (1.40, [  # 开心幼犬吠（取后半兴奋段）
        seg("dog_happy_puppy_59", 1.5, 1.3, 1.00, 1.00, 0.00),
    ]),
    "dog_05_play.wav": (1.60, [  # 拉布拉多玩耍吠
        seg("dog_lab_playing_50", 0.0, 1.5, 1.00, 1.00, 0.00),
    ]),
    "dog_06_walk.wav": (1.95, [  # 汪汪 + 兴奋吠（出门）
        seg("dog_bark_twice_60", 0.0, 1.0, 1.00, 1.00, 0.00),
        seg("dog_happy_puppy_59", 3.0, 1.0, 1.00, 0.90, 0.95),
    ]),
    "dog_07_sleep.wav": (1.45, [  # 呜咽降速降调（困意）
        seg("dog_whimper2_58", 0.0, 1.3, 0.90, 0.70, 0.00),
    ]),
    "dog_08_comfort.wav": (1.50, [  # 轻呜咽（安抚）
        seg("dog_whimper_sad_52", 0.0, 1.4, 1.00, 0.80, 0.00),
    ]),
    "dog_09_talk.wav": (1.15, [  # 短兴奋吠（友好）
        seg("dog_happy_puppy_59", 4.5, 1.0, 1.00, 0.85, 0.00),
    ]),
}

def write_wav(path, canvas, total):
    n = int(total * SR)
    x = np.zeros(n)
    c = canvas[:n]
    x[: len(c)] = c
    x = np.tanh(x * 1.15)
    peak = float(np.max(np.abs(x)))
    if peak > 0:
        x = x / peak * 0.92
    f = min(int(0.03 * SR), n // 4)
    x[:f] *= np.linspace(0, 1, f)
    x[-f:] *= np.linspace(1, 0, f)
    pcm = (x * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

def main():
    os.makedirs(OUT, exist_ok=True)
    for key, (total, segs) in LAYOUT.items():
        canvas = np.zeros(int(total * SR), dtype=np.float64)
        for (name, start, dur, speed, gain, at) in segs:
            x = decode(name)
            s = resampled(cut(x, start, dur), speed)
            place(canvas, s, at, gain)
        write_wav(os.path.join(OUT, key), canvas, total)
        print(f"OK {key}  {total:.2f}s  ({len(segs)} seg)")
    print("\ndone ->", os.path.abspath(OUT))

if __name__ == "__main__":
    main()
