#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
毛语通 v1.1 · 真实叫声组装（行为学修订版）
素材源：Wikimedia Commons（CC0/PD/CC BY/CC BY-SA，可商用）
配方原则（依据 Yin & McCowan 2004 / Schötz MEOWSIC / Morton 1977）：
- 猫唤回/问候：颤音与短喵（高频圆滑）；安抚/睡觉：咕噜；骂/制止：哈气与低吼
- 狗唤回/玩耍/夸奖：高频短吠（圆滑）；骂/制止：低吼+低频吠；安抚/睡：呜咽渐弱
- 每个意图 2 条变体（素材/剪辑/速度不同），播放端随机轮换
"""
import os
import subprocess
import wave

import numpy as np

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "..", "_sfx_raw2")
OUT = os.path.join(HERE, "..", "assets", "sounds")
FFMPEG = "ffmpeg"

_cache = {}

def decode(name):
    if name in _cache:
        return _cache[name]
    src = os.path.join(RAW, name + ".wav")
    cmd = [FFMPEG, "-v", "error", "-i", src, "-f", "f32le", "-ac", "1",
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
# 变体配方：assets/sounds/{species}_{ii}_{id}.wav 为主文件
#           {species}_{ii}_{id}_v1.wav 为变体二
# ============================================================
LAYOUT = {
    # ================= 猫 =================
    # 00 come：颤音唤崽信号；变体：短喵呼唤
    "cat_00_come.wav": (1.60, [
        seg("meow_audio_file", 20.0, 0.55, 0.92, 1.00, 0.00),
        seg("meow_audio_file", 20.0, 0.55, 0.86, 0.90, 0.75),
    ]),
    "cat_00_come_v1.wav": (1.40, [
        seg("meow_pleading", 0.6, 0.6, 0.95, 1.00, 0.00),
        seg("meow_female", 0.05, 0.65, 0.92, 0.85, 0.70),
    ]),
    # 01 praise：咕噜+甜喵；变体：双短喵
    "cat_01_praise.wav": (2.20, [
        seg("purr_bertie", 0.5, 1.6, 1.0, 0.9, 0.00),
        seg("meow_plaintive", 0.02, 0.6, 1.0, 0.75, 1.55),
    ]),
    "cat_01_praise_v1.wav": (1.30, [
        seg("meow_female", 0.05, 0.6, 1.0, 0.95, 0.00),
        seg("meow_plaintive", 0.02, 0.55, 1.06, 0.9, 0.68),
    ]),
    # 02 scold：哈气式防御警告；变体：不悦的长喵降调
    "cat_02_scold.wav": (1.50, [
        seg("meow_impatient", 0.3, 0.7, 0.88, 1.0, 0.00),
        seg("meow_impatient", 1.5, 0.6, 0.82, 0.9, 0.80),
    ]),
    "cat_02_scold_v1.wav": (1.60, [
        seg("meow_siamese", 0.1, 0.8, 0.80, 1.0, 0.00),
        seg("meow_notrip", 2.0, 0.6, 0.85, 0.85, 0.90),
    ]),
    # 03 stop：一声短哈气；变体：急促双喵
    "cat_03_stop.wav": (0.90, [
        seg("meow_impatient", 3.1, 0.55, 0.95, 1.0, 0.00),
    ]),
    "cat_03_stop_v1.wav": (1.05, [
        seg("meow_female", 0.05, 0.45, 1.08, 1.0, 0.00),
        seg("meow_female", 0.05, 0.45, 1.12, 0.9, 0.52),
    ]),
    # 04 eat：索求喵连叫；变体：另一个体的索求喵
    "cat_04_eat.wav": (1.90, [
        seg("meow_hungry_want", 0.4, 0.8, 1.0, 1.0, 0.00),
        seg("meow_hungry_want", 2.6, 0.75, 0.96, 0.9, 1.0),
    ]),
    "cat_04_eat_v1.wav": (1.70, [
        seg("meow_audio_file", 24.0, 0.75, 1.0, 1.0, 0.00),
        seg("meow_pleading", 2.2, 0.7, 0.98, 0.9, 0.9),
    ]),
    # 05 play：轻快短喵组合；变体：高频系列喵
    "cat_05_play.wav": (1.30, [
        seg("meow_audio_file", 30.5, 0.5, 1.08, 1.0, 0.00),
        seg("meow_audio_file", 30.5, 0.5, 1.14, 0.9, 0.62),
    ]),
    "cat_05_play_v1.wav": (1.50, [
        seg("meow_series", 0.8, 0.6, 1.05, 0.95, 0.00),
        seg("meow_series", 3.0, 0.6, 1.1, 0.9, 0.72),
    ]),
    # 06 walk：期待的长喵；变体：双音节
    "cat_06_walk.wav": (1.60, [
        seg("meow_greek_nr", 0.0, 0.7, 1.0, 1.0, 0.00),
        seg("meow_pleading", 0.6, 0.8, 0.9, 0.9, 0.80),
    ]),
    "cat_06_walk_v1.wav": (1.70, [
        seg("meow_audio_file", 27.0, 0.8, 0.95, 1.0, 0.00),
        seg("meow_female", 0.05, 0.7, 0.9, 0.85, 0.95),
    ]),
    # 07 sleep：纯咕噜（低频规律振动，天然白噪音）
    "cat_07_sleep.wav": (2.60, [
        seg("purr_cat", 1.0, 2.5, 1.0, 0.95, 0.00),
    ]),
    "cat_07_sleep_v1.wav": (2.60, [
        seg("purr_bertie", 3.0, 2.5, 0.95, 0.95, 0.00),
    ]),
    # 08 comfort：稳定咕噜；变体：咕噜+轻喵
    "cat_08_comfort.wav": (2.40, [
        seg("purr_katzenschnurren", 2.0, 2.3, 1.0, 0.9, 0.00),
    ]),
    "cat_08_comfort_v1.wav": (2.60, [
        seg("purr_bertie", 0.5, 1.8, 1.0, 0.9, 0.00),
        seg("meow_plaintive", 0.02, 0.5, 0.85, 0.6, 1.95),
    ]),
    # 09 talk：颤音+短喵问候；变体：单短喵
    "cat_09_talk.wav": (1.25, [
        seg("meow_audio_file", 20.0, 0.5, 1.05, 0.95, 0.00),
        seg("meow_plaintive", 0.02, 0.5, 0.98, 0.85, 0.62),
    ]),
    "cat_09_talk_v1.wav": (1.05, [
        seg("meow_greek_nr", 0.0, 0.75, 1.0, 0.95, 0.00),
    ]),
    # ================= 狗 =================
    # 00 come：短促吠两声（高频圆滑）
    "dog_00_come.wav": (1.30, [
        seg("bark_single", 0.1, 0.45, 1.0, 1.0, 0.00),
        seg("bark_single", 0.75, 0.45, 1.02, 0.95, 0.62),
    ]),
    "dog_00_come_v1.wav": (1.20, [
        seg("bark_perro", 0.5, 0.4, 1.05, 1.0, 0.00),
        seg("bark_perro", 1.4, 0.45, 1.0, 0.95, 0.58),
    ]),
    # 01 praise：轻快连串吠（play 情境）
    "dog_01_praise.wav": (1.60, [
        seg("bark_perro", 2.4, 0.4, 1.05, 1.0, 0.00),
        seg("bark_perro", 3.2, 0.4, 1.08, 0.95, 0.50),
        seg("bark_perro", 4.0, 0.45, 1.02, 0.9, 1.02),
    ]),
    "dog_01_praise_v1.wav": (1.35, [
        seg("bark_single2", 0.2, 0.4, 1.06, 1.0, 0.00),
        seg("bark_single2", 1.1, 0.45, 1.02, 0.9, 0.55),
    ]),
    # 02 scold：低吼开场+低频吠（威胁语境）
    "dog_02_scold.wav": (2.00, [
        seg("growl_a", 0.3, 0.9, 0.95, 1.0, 0.00),
        seg("bark_single", 0.1, 0.5, 0.82, 0.95, 1.0),
    ]),
    "dog_02_scold_v1.wav": (2.10, [
        seg("growl_b", 0.2, 0.9, 0.9, 1.0, 0.00),
        seg("bark_rottweiler", 3.0, 0.55, 0.85, 0.95, 1.05),
        seg("bark_rottweiler", 4.2, 0.55, 0.85, 0.9, 1.55),
    ]),
    # 03 stop：两声果断中频吠
    "dog_03_stop.wav": (1.15, [
        seg("bark_single2", 0.2, 0.4, 0.95, 1.0, 0.00),
        seg("bark_single2", 0.95, 0.42, 0.92, 0.95, 0.55),
    ]),
    "dog_03_stop_v1.wav": (1.10, [
        seg("bark_de", 0.0, 0.42, 1.0, 1.0, 0.00),
        seg("bark_de", 0.55, 0.42, 0.97, 0.9, 0.56),
    ]),
    # 04 eat：兴奋期待吠
    "dog_04_eat.wav": (1.40, [
        seg("bark_perro", 0.5, 0.45, 1.06, 1.0, 0.00),
        seg("bark_perro", 1.4, 0.5, 1.1, 0.95, 0.55),
    ]),
    "dog_04_eat_v1.wav": (1.30, [
        seg("bark_single", 0.75, 0.45, 1.08, 1.0, 0.00),
        seg("bark_single", 1.7, 0.5, 1.02, 0.9, 0.6),
    ]),
    # 05 play：玩耍连串吠
    "dog_05_play.wav": (1.80, [
        seg("bark_perro", 2.4, 0.42, 1.06, 1.0, 0.00),
        seg("bark_perro", 3.3, 0.42, 1.1, 0.95, 0.52),
        seg("bark_perro", 4.2, 0.5, 1.04, 0.92, 1.06),
    ]),
    "dog_05_play_v1.wav": (1.55, [
        seg("bark_single2", 0.2, 0.42, 1.08, 1.0, 0.00),
        seg("bark_single2", 1.05, 0.45, 1.05, 0.95, 0.55),
        seg("bark_single2", 1.95, 0.45, 1.0, 0.9, 1.08),
    ]),
    # 06 walk：出门兴奋吠
    "dog_06_walk.wav": (1.70, [
        seg("bark_perro", 0.5, 0.42, 1.04, 1.0, 0.00),
        seg("bark_perro", 1.35, 0.45, 1.02, 0.95, 0.55),
        seg("bark_single", 0.1, 0.45, 1.0, 0.85, 1.12),
    ]),
    "dog_06_walk_v1.wav": (1.55, [
        seg("bark_single2", 0.2, 0.42, 1.02, 1.0, 0.00),
        seg("bark_single2", 1.1, 0.45, 1.0, 0.92, 0.58),
        seg("bark_perro", 2.4, 0.42, 1.05, 0.85, 1.12),
    ]),
    # 07 sleep：轻呜咽渐弱
    "dog_07_sleep.wav": (2.20, [
        seg("growl_b", 0.3, 1.0, 0.8, 0.55, 0.00),
        seg("howl_jem", 0.4, 1.1, 0.82, 0.45, 1.05),
    ]),
    "dog_07_sleep_v1.wav": (2.00, [
        seg("howl_jem", 2.6, 1.4, 0.78, 0.5, 0.00),
    ]),
    # 08 comfort：低柔呜咽（接触性安抚音）
    "dog_08_comfort.wav": (2.10, [
        seg("growl_a", 1.6, 1.2, 0.85, 0.7, 0.00),
        seg("howl_jem", 0.4, 0.8, 0.85, 0.4, 1.25),
    ]),
    "dog_08_comfort_v1.wav": (2.00, [
        seg("growl_b", 0.2, 1.3, 0.88, 0.65, 0.00),
    ]),
    # 09 talk：友好单吠+轻呜
    "dog_09_talk.wav": (1.25, [
        seg("bark_single", 0.1, 0.45, 1.04, 0.95, 0.00),
        seg("howl_jem", 3.9, 0.6, 0.9, 0.45, 0.6),
    ]),
    "dog_09_talk_v1.wav": (1.15, [
        seg("bark_de", 0.0, 0.4, 1.05, 0.95, 0.00),
        seg("bark_perro", 4.0, 0.4, 1.0, 0.8, 0.52),
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
    # 清理旧合成音（物种_序号_意图.wav 会被同名覆盖；遗留的老命名先删）
    for old in os.listdir(OUT):
        if old.endswith(".wav") and ("_" in old):
            pass  # 同名覆盖；保留 v1 缺失时的回退
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
