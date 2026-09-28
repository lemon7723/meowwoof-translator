#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
毛语通 v1.2 · 真实叫声组装（多源采样版）
源池：
  _sfx_raw2/ = Wikimedia Commons（22 条，CC0/PD/CC BY/CC BY-SA）
  _sfx_raw3/ = Freesound CC0 采样（45 条，去除低信噪比后约 37 条可用）
配方原则（依据 Yin & McCowan 2004 / Schötz MEOWSIC / Morton 1977）：
  每意图 3 变体 × 猫狗 = 60 条，每个变体来自不同录音（不同录音人/个体），
  播放端随机轮换 → "来来去去那几个声" 问题根治。
"""
import os
import wave

import numpy as np

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
RAW2 = os.path.join(HERE, "..", "_sfx_raw2")
RAW3 = os.path.join(HERE, "..", "_sfx_raw3")
OUT = os.path.join(HERE, "..", "assets", "sounds")

_cache = {}

def decode(name):
    """name 不带扩展名；依次在 raw3/raw2 查找"""
    if name in _cache:
        return _cache[name]
    for base in (RAW3, RAW2):
        src = os.path.join(base, name + ".wav")
        if os.path.exists(src):
            break
    else:
        raise FileNotFoundError(name)
    import subprocess
    cmd = ["ffmpeg", "-v", "error", "-i", src, "-f", "f32le", "-ac", "1",
           "-ar", str(SR), "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).copy()
    p = float(np.max(np.abs(x)))
    if p > 0:
        x = x / p
    _cache[name] = x
    return x

def resampled(x, speed):
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

# ============================================================
# 60 条配方。每条尽量来自不同录音源；剪辑点选在叫声起点。
# ============================================================
LAYOUT = {
    # ============ 猫（意图序号 00-09） ============
    # 00 come：颤音/短喵呼唤（高频圆滑）
    "cat_00_come.wav": (1.30, [
        seg("meow_110011", 0.10, 0.60, 0.96, 1.00, 0.00),
        seg("meow_110011", 0.10, 0.55, 0.92, 0.85, 0.68),
    ]),
    "cat_00_come_v1.wav": (1.35, [
        seg("meow2_196251", 2.0, 0.6, 0.98, 1.00, 0.00),
        seg("meow2_196251", 4.2, 0.55, 0.94, 0.85, 0.72),
    ]),
    "cat_00_come_v2.wav": (1.45, [
        seg("meow_audio_file", 20.0, 0.55, 0.94, 1.00, 0.00),
        seg("meow_female", 0.05, 0.6, 0.92, 0.85, 0.78),
    ]),
    # 01 praise：咕噜+甜喵 / 双短喵 / 幼猫喵
    "cat_01_praise.wav": (2.20, [
        seg("purr_656500", 1.0, 1.5, 1.0, 0.9, 0.00),
        seg("meow_479272", 0.05, 0.55, 1.0, 0.8, 1.60),
    ]),
    "cat_01_praise_v1.wav": (1.30, [
        seg("meow2_448084", 0.05, 0.55, 1.0, 1.0, 0.00),
        seg("meow_479272", 0.05, 0.5, 1.05, 0.9, 0.65),
    ]),
    "cat_01_praise_v2.wav": (2.00, [
        seg("purr_bertie", 1.0, 1.5, 1.0, 0.9, 0.00),
        seg("meow_508686", 0.3, 0.45, 1.0, 0.8, 1.55),
    ]),
    # 02 scold：不悦长喵降调 / 哈气式 / 低哑喵
    "cat_02_scold.wav": (1.60, [
        seg("meow2_51809", 0.6, 0.7, 0.86, 1.0, 0.00),
        seg("meow2_51809", 2.2, 0.6, 0.80, 0.9, 0.85),
    ]),
    "cat_02_scold_v1.wav": (1.50, [
        seg("hiss_485952", 0.0, 0.55, 0.95, 1.0, 0.00),
        seg("meow_66518", 1.0, 0.6, 0.85, 0.9, 0.75),
    ]),
    "cat_02_scold_v2.wav": (1.70, [
        seg("meow_notrip", 2.0, 0.75, 0.82, 1.0, 0.00),
        seg("hiss_146963", 0.2, 0.5, 0.9, 0.85, 1.0),
    ]),
    # 03 stop：一声短哈气 / 急促双喵 / 短促嘶
    "cat_03_stop.wav": (0.90, [
        seg("hiss_485952", 0.0, 0.6, 1.0, 1.0, 0.00),
    ]),
    "cat_03_stop_v1.wav": (1.05, [
        seg("meow2_448084", 0.05, 0.42, 1.1, 1.0, 0.00),
        seg("meow2_448084", 0.05, 0.42, 1.16, 0.9, 0.52),
    ]),
    "cat_03_stop_v2.wav": (1.00, [
        seg("hiss_455495", 3.0, 0.65, 1.0, 1.0, 0.00),
    ]),
    # 04 eat：索求喵连叫（不同个体三版）
    "cat_04_eat.wav": (1.90, [
        seg("meow_110011", 0.10, 0.8, 1.0, 1.0, 0.00),
        seg("meow_66518", 0.3, 0.75, 0.98, 0.9, 0.95),
    ]),
    "cat_04_eat_v1.wav": (1.80, [
        seg("meow2_196251", 2.0, 0.75, 1.0, 1.0, 0.00),
        seg("meow_audio_file", 24.0, 0.7, 0.98, 0.9, 0.95),
    ]),
    "cat_04_eat_v2.wav": (1.75, [
        seg("meow_hungry_want", 0.4, 0.8, 1.0, 1.0, 0.00),
        seg("meow_508686", 0.3, 0.65, 1.02, 0.9, 0.95),
    ]),
    # 05 play：轻快短喵 / 高频系列 / 幼猫游戏音
    "cat_05_play.wav": (1.30, [
        seg("meow_479272", 0.05, 0.5, 1.08, 1.0, 0.00),
        seg("meow_479272", 0.05, 0.48, 1.14, 0.9, 0.60),
    ]),
    "cat_05_play_v1.wav": (1.45, [
        seg("meow2_149191", 1.0, 0.6, 1.06, 1.0, 0.00),
        seg("meow2_149191", 3.2, 0.55, 1.12, 0.9, 0.72),
    ]),
    "cat_05_play_v2.wav": (1.50, [
        seg("meow_series", 0.8, 0.6, 1.05, 0.95, 0.00),
        seg("meow_508686", 0.3, 0.5, 1.1, 0.9, 0.78),
    ]),
    # 06 walk：期待长喵 / 双音节 / 上扬喵
    "cat_06_walk.wav": (1.55, [
        seg("meow_greek_nr", 0.0, 0.7, 1.0, 1.0, 0.00),
        seg("meow_pleading", 0.6, 0.75, 0.9, 0.9, 0.78),
    ]),
    "cat_06_walk_v1.wav": (1.55, [
        seg("meow_66518", 0.3, 0.7, 0.95, 1.0, 0.00),
        seg("meow_110011", 0.10, 0.65, 0.9, 0.85, 0.82),
    ]),
    "cat_06_walk_v2.wav": (1.60, [
        seg("meow_pleading", 0.6, 0.8, 0.95, 1.0, 0.00),
        seg("meow2_196251", 4.2, 0.6, 0.9, 0.85, 0.92),
    ]),
    # 07 sleep：纯咕噜（三只不同的猫）
    "cat_07_sleep.wav": (2.60, [
        seg("purr_cat", 1.0, 2.5, 1.0, 0.95, 0.00),
    ]),
    "cat_07_sleep_v1.wav": (2.60, [
        seg("purr_126151", 3.0, 2.5, 1.0, 0.95, 0.00),
    ]),
    "cat_07_sleep_v2.wav": (2.60, [
        seg("purr_bertie", 4.0, 2.5, 0.98, 0.95, 0.00),
    ]),
    # 08 comfort：稳定咕噜 / 咕噜+轻喵 / 咕噜渐弱
    "cat_08_comfort.wav": (2.40, [
        seg("purr_656500", 2.0, 2.3, 1.0, 0.9, 0.00),
    ]),
    "cat_08_comfort_v1.wav": (2.60, [
        seg("purr_126151", 8.0, 1.8, 1.0, 0.9, 0.00),
        seg("meow_508686", 0.3, 0.45, 0.85, 0.55, 1.95),
    ]),
    "cat_08_comfort_v2.wav": (2.50, [
        seg("purr_katzenschnurren", 2.0, 2.4, 1.0, 0.85, 0.00),
    ]),
    # 09 talk：颤音+短喵 / 单短喵 / 幼猫应答
    "cat_09_talk.wav": (1.20, [
        seg("meow_110011", 0.10, 0.5, 1.05, 0.95, 0.00),
        seg("meow_plaintive", 0.02, 0.5, 0.98, 0.85, 0.60),
    ]),
    "cat_09_talk_v1.wav": (1.10, [
        seg("meow_greek_nr", 0.0, 0.75, 1.0, 0.95, 0.00),
    ]),
    "cat_09_talk_v2.wav": (1.30, [
        seg("meow2_448084", 0.05, 0.55, 0.98, 1.0, 0.00),
        seg("meow_female", 0.05, 0.5, 0.95, 0.8, 0.68),
    ]),
    # ============ 狗 ============
    # 00 come：短促吠两声（高频圆滑，三只不同的狗）
    "dog_00_come.wav": (1.30, [
        seg("bark_single", 0.1, 0.45, 1.0, 1.0, 0.00),
        seg("bark_single", 0.75, 0.45, 1.02, 0.95, 0.62),
    ]),
    "dog_00_come_v1.wav": (1.25, [
        seg("bark2_583142", 0.1, 0.42, 1.05, 1.0, 0.00),
        seg("bark2_583142", 0.95, 0.45, 1.0, 0.95, 0.60),
    ]),
    "dog_00_come_v2.wav": (1.35, [
        seg("bark2_211607", 1.0, 0.45, 1.02, 1.0, 0.00),
        seg("bark2_211607", 2.1, 0.45, 0.98, 0.95, 0.65),
    ]),
    # 01 praise：轻快连串吠（play 情境，三源）
    "dog_01_praise.wav": (1.60, [
        seg("bark_perro", 2.4, 0.4, 1.05, 1.0, 0.00),
        seg("bark_perro", 3.2, 0.4, 1.08, 0.95, 0.50),
        seg("bark_perro", 4.0, 0.45, 1.02, 0.9, 1.02),
    ]),
    "dog_01_praise_v1.wav": (1.55, [
        seg("bark_868412", 0.3, 0.42, 1.06, 1.0, 0.00),
        seg("bark_868412", 1.3, 0.42, 1.1, 0.95, 0.52),
        seg("bark_868412", 2.4, 0.45, 1.04, 0.9, 1.06),
    ]),
    "dog_01_praise_v2.wav": (1.50, [
        seg("bark2_591137", 0.5, 0.42, 1.05, 1.0, 0.00),
        seg("bark2_591137", 1.6, 0.42, 1.08, 0.95, 0.52),
        seg("bark2_591137", 2.7, 0.45, 1.02, 0.9, 1.06),
    ]),
    # 02 scold：低吼开场+低频吠（三组低吼源）
    "dog_02_scold.wav": (2.00, [
        seg("growl_a", 0.3, 0.9, 0.95, 1.0, 0.00),
        seg("bark_single", 0.1, 0.5, 0.82, 0.95, 1.0),
    ]),
    "dog_02_scold_v1.wav": (2.10, [
        seg("growl_337167", 0.5, 0.9, 0.92, 1.0, 0.00),
        seg("bark_rottweiler", 3.0, 0.55, 0.85, 0.95, 1.05),
        seg("bark_rottweiler", 4.2, 0.55, 0.85, 0.9, 1.55),
    ]),
    "dog_02_scold_v2.wav": (2.05, [
        seg("growl_829986", 0.0, 0.9, 0.9, 1.0, 0.00),
        seg("bark_440866", 0.5, 0.5, 0.84, 0.95, 1.05),
        seg("bark_440866", 1.6, 0.5, 0.84, 0.9, 1.52),
    ]),
    # 03 stop：两声果断中频吠（三源）
    "dog_03_stop.wav": (1.15, [
        seg("bark_single2", 0.2, 0.4, 0.95, 1.0, 0.00),
        seg("bark_single2", 0.95, 0.42, 0.92, 0.95, 0.55),
    ]),
    "dog_03_stop_v1.wav": (1.10, [
        seg("bark_de", 0.0, 0.42, 1.0, 1.0, 0.00),
        seg("bark_de", 0.55, 0.42, 0.97, 0.9, 0.56),
    ]),
    "dog_03_stop_v2.wav": (1.15, [
        seg("bark_832435", 0.2, 0.42, 1.0, 1.0, 0.00),
        seg("bark_832435", 1.0, 0.45, 0.96, 0.95, 0.58),
    ]),
    # 04 eat：兴奋期待吠（三源）
    "dog_04_eat.wav": (1.40, [
        seg("bark_perro", 0.5, 0.45, 1.06, 1.0, 0.00),
        seg("bark_perro", 1.4, 0.5, 1.1, 0.95, 0.55),
    ]),
    "dog_04_eat_v1.wav": (1.30, [
        seg("bark_single", 0.75, 0.45, 1.08, 1.0, 0.00),
        seg("bark_single", 1.7, 0.5, 1.02, 0.9, 0.6),
    ]),
    "dog_04_eat_v2.wav": (1.45, [
        seg("bark2_608732", 0.8, 0.42, 1.06, 1.0, 0.00),
        seg("bark2_608732", 2.0, 0.48, 1.1, 0.92, 0.56),
    ]),
    # 05 play：玩耍连串吠（三源）
    "dog_05_play.wav": (1.80, [
        seg("bark_perro", 2.4, 0.42, 1.06, 1.0, 0.00),
        seg("bark_perro", 3.3, 0.42, 1.1, 0.95, 0.52),
        seg("bark_perro", 4.2, 0.5, 1.04, 0.92, 1.06),
    ]),
    "dog_05_play_v1.wav": (1.70, [
        seg("bark_625501", 0.2, 0.42, 1.06, 1.0, 0.00),
        seg("bark_625501", 1.0, 0.42, 1.1, 0.95, 0.52),
        seg("bark_625501", 1.9, 0.5, 1.04, 0.92, 1.06),
    ]),
    "dog_05_play_v2.wav": (1.65, [
        seg("bark2_583142", 0.1, 0.42, 1.08, 1.0, 0.00),
        seg("bark2_583142", 0.95, 0.42, 1.05, 0.95, 0.55),
        seg("bark2_583142", 1.85, 0.45, 1.0, 0.9, 1.10),
    ]),
    # 06 walk：出门兴奋吠（三源）
    "dog_06_walk.wav": (1.70, [
        seg("bark_perro", 0.5, 0.42, 1.04, 1.0, 0.00),
        seg("bark_perro", 1.35, 0.45, 1.02, 0.95, 0.55),
        seg("bark_single", 0.1, 0.45, 1.0, 0.85, 1.12),
    ]),
    "dog_06_walk_v1.wav": (1.65, [
        seg("bark2_591137", 0.5, 0.42, 1.02, 1.0, 0.00),
        seg("bark2_591137", 1.6, 0.45, 1.0, 0.92, 0.56),
        seg("bark2_583142", 0.1, 0.42, 1.05, 0.85, 1.14),
    ]),
    "dog_06_walk_v2.wav": (1.55, [
        seg("bark_868412", 0.3, 0.42, 1.02, 1.0, 0.00),
        seg("bark_868412", 1.3, 0.45, 1.0, 0.92, 0.56),
        seg("bark_749352", 2.0, 0.42, 1.05, 0.85, 1.10),
    ]),
    # 07 sleep：轻呜咽渐弱（三源）
    "dog_07_sleep.wav": (2.20, [
        seg("whine_455745", 1.0, 1.2, 0.82, 0.6, 0.00),
        seg("whine_455745", 3.5, 0.9, 0.75, 0.45, 1.28),
    ]),
    "dog_07_sleep_v1.wav": (2.10, [
        seg("whine_417144", 2.0, 1.3, 0.8, 0.55, 0.00),
        seg("whine_417144", 6.0, 0.8, 0.72, 0.4, 1.35),
    ]),
    "dog_07_sleep_v2.wav": (2.00, [
        seg("whine_461526", 1.0, 1.4, 0.78, 0.55, 0.00),
    ]),
    # 08 comfort：低柔呜咽/接触音（三源）
    "dog_08_comfort.wav": (2.10, [
        seg("whine_455745", 4.0, 1.4, 0.88, 0.7, 0.00),
        seg("howl_jem", 0.4, 0.7, 0.85, 0.35, 1.45),
    ]),
    "dog_08_comfort_v1.wav": (2.00, [
        seg("whine_461526", 4.0, 1.5, 0.9, 0.7, 0.00),
    ]),
    "dog_08_comfort_v2.wav": (2.15, [
        seg("growl_b", 0.2, 1.3, 0.88, 0.6, 0.00),
        seg("whine_505827", 1.0, 0.9, 0.85, 0.4, 1.35),
    ]),
    # 09 talk：友好单吠+轻呜（三源）
    "dog_09_talk.wav": (1.25, [
        seg("bark_single", 0.1, 0.45, 1.04, 0.95, 0.00),
        seg("howl_jem", 3.9, 0.6, 0.9, 0.45, 0.6),
    ]),
    "dog_09_talk_v1.wav": (1.15, [
        seg("bark2_583142", 0.1, 0.4, 1.05, 0.95, 0.00),
        seg("whine_455745", 1.0, 0.5, 0.95, 0.4, 0.55),
    ]),
    "dog_09_talk_v2.wav": (1.20, [
        seg("bark_832435", 0.2, 0.4, 1.05, 0.95, 0.00),
        seg("bark_868412", 3.5, 0.4, 1.0, 0.8, 0.55),
    ]),
}

def write_wav(path, canvas, total):
    n = int(total * SR)
    x = np.zeros(n)
    c = canvas[:n]
    x[: len(c)] = c
    x = np.tanh(x * 1.12)
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
    ok = 0
    for key, (total, segs) in LAYOUT.items():
        try:
            canvas = np.zeros(int(total * SR), dtype=np.float64)
            for (name, start, dur, speed, gain, at) in segs:
                x = decode(name)
                s = resampled(cut(x, start, dur), speed)
                place(canvas, s, at, gain)
            write_wav(os.path.join(OUT, key), canvas, total)
            ok += 1
            print(f"OK {key}  {total:.2f}s")
        except FileNotFoundError as e:
            print(f"MISS {key}: {e}")
    print(f"\n{ok}/{len(LAYOUT)} -> {OUT}")

if __name__ == "__main__":
    main()
