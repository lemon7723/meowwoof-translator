#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
毛语通 · 预设叫声合成器
用谐波 + 噪声建模合成 20 条猫/狗叫声（10 意图 × 2 物种）。
纯 numpy，无其他依赖。输出 22050Hz / 16bit / 单声道 WAV。
每条叫声 = 若干"音节"叠加 + 轻呼吸噪声底；确定性种子，可重复生成。
用法: python tools/synth_calls.py
"""
import os
import wave

import numpy as np

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sounds")

# ---------------------------------------------------------------- 基元

def _lp_ma(x, hz):
    """移动平均低通（截止约 hz）"""
    w = max(2, int(SR / max(hz, 20)))
    return np.convolve(x, np.ones(w) / w, mode="same")

def _hp(x, hz):
    return x - _lp_ma(x, hz)

def _norm(x):
    m = np.max(np.abs(x))
    return x / m if m > 1e-9 else x

def tone(dur, f_curve, n_harm=11, tilt=1.0, bright=1.0, vib_hz=0.0, vib_amt=0.0, jitter=0.0):
    """谐波音。f_curve: t(秒) -> 频率(Hz) 的函数"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = f_curve(t).copy()
    if jitter > 0:  # 低频抖动（动物声带不完全稳定）
        rng = np.random.default_rng(7)
        slow = _lp_ma(rng.uniform(-1, 1, n), 30)
        slow = _norm(slow) * jitter
        f = f * (1 + slow / np.maximum(f, 1))
    if vib_hz > 0:
        f = f * (1 + vib_amt * np.sin(2 * np.pi * vib_hz * t))
    phase = 2 * np.pi * np.cumsum(f) / SR
    out = np.zeros(n)
    for k in range(1, n_harm + 1):
        if k * np.max(f) >= SR * 0.45:
            break
        amp = (1.0 / k**tilt) * (bright if k > 1 else 1.0)
        out += amp * np.sin(k * phase)
    return out / (np.max(np.abs(out)) + 1e-9)

def env_ad(n, atk, dec, curve=1.5):
    """attack-decay 包络"""
    e = np.ones(n)
    an = max(1, min(n - 1, int(atk * SR)))
    dn = max(1, min(n - an, int(dec * SR)))
    e[:an] = np.linspace(0, 1, an) ** 0.5
    e[n - dn:] = np.linspace(1, 0, dn) ** curve
    return e

def glide(f0, f1, dur, shape="lin"):
    def fc(t):
        p = t / dur
        if shape == "cos":
            p = 0.5 - 0.5 * np.cos(np.pi * p)
        return f0 + (f1 - f0) * p
    return fc

def arc(f0, f1, f2, dur):
    """先升后降的频率曲线（嚎叫）"""
    def fc(t):
        p = t / dur
        return np.where(p < 0.4,
                        f0 + (f1 - f0) * (p / 0.4),
                        f1 + (f2 - f1) * ((p - 0.4) / 0.6))
    return fc

def place(canvas, sig, t0):
    i0 = int(t0 * SR)
    i1 = min(len(canvas), i0 + len(sig))
    canvas[i0:i1] += sig[: i1 - i0]

def breath(dur, amt=0.10):
    n = int(dur * SR)
    rng = np.random.default_rng(42)
    x = _lp_ma(rng.uniform(-1, 1, n), 900)
    return _norm(x) * amt

# ---------------------------------------------------------------- 音色

def bark(f0=640, dur=0.10, amp=1.0):
    """汪：短促爆破感谐波 + 胸腔噪声"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = glide(f0 * 1.05, f0 * 0.88, dur)(t)
    body = tone(dur, lambda tt: f, n_harm=9, tilt=0.65, bright=2.2)
    chest = _norm(_lp_ma(np.random.default_rng(3).uniform(-1, 1, n), 320))
    sig = body * env_ad(n, 0.008, dur * 0.72) + chest * 0.30 * env_ad(n, 0.006, dur * 0.6)
    return sig * amp

def whine(f0a=500, f0b=760, dur=0.35, amp=1.0):
    """呜/咿：上扬带颤的哀调"""
    n = int(dur * SR)
    sig = tone(dur, glide(f0a, f0b, dur, "cos"), n_harm=10, tilt=1.15,
               bright=1.15, vib_hz=6.5, vib_amt=0.025)
    return sig * env_ad(n, 0.035, dur * 0.35) * amp

def howl(f0=300, peak=460, end=340, dur=0.6, amp=1.0):
    """嗷呜：先升后降的长嚎"""
    n = int(dur * SR)
    sig = tone(dur, arc(f0, peak, end, dur), n_harm=12, tilt=1.0, bright=1.3,
               vib_hz=5.5, vib_amt=0.018)
    return sig * env_ad(n, 0.06, dur * 0.38) * amp

def growl(f0=145, dur=0.8, amp=1.0):
    """呜——：低沉威胁"""
    n = int(dur * SR)
    rng = np.random.default_rng(11)
    slow = _norm(_lp_ma(rng.uniform(-1, 1, n), 22))
    fc = lambda t: f0 * (1 + 0.06 * slow)
    body = tone(dur, fc, n_harm=10, tilt=0.85, bright=0.75, jitter=6)
    rumble = _norm(_lp_ma(np.random.default_rng(5).uniform(-1, 1, n), 180))
    sig = body * 0.9 + rumble * 0.45
    return sig * env_ad(n, 0.05, dur * 0.3) * amp

def purr(f0=95, dur=1.2, amp=1.0):
    """咕噜：26Hz 振幅调制的低频和谐声"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    body = tone(dur, lambda tt: np.full_like(tt, f0), n_harm=9, tilt=1.5, bright=0.6)
    mod = 0.55 + 0.45 * np.abs(np.sin(2 * np.pi * 26 * t))
    sig = body * mod + _norm(breath(dur, 1.0)) * 0.12
    return sig * env_ad(n, 0.06, dur * 0.25) * amp

def meow(f0a=620, f0b=540, dur=0.28, amp=1.0, bright=1.0):
    """咪呜：开口→收口的双元音滑音"""
    n = int(dur * SR)
    sig = tone(dur, glide(f0a, f0b, dur, "cos"), n_harm=10, tilt=1.05,
               bright=bright, vib_hz=7, vib_amt=0.02)
    return sig * env_ad(n, 0.025, dur * 0.45) * amp

def chirp(f0=720, f1=None, dur=0.10, amp=1.0):
    """咪！短促高音节"""
    f1 = f1 if f1 is not None else f0 * 1.18
    n = int(dur * SR)
    sig = tone(dur, glide(f0, f1, dur), n_harm=7, tilt=0.7, bright=1.8)
    return sig * env_ad(n, 0.006, dur * 0.5) * amp

def hiss(dur=0.25, amp=1.0):
    """哈/嘶：高频擦音"""
    n = int(dur * SR)
    rng = np.random.default_rng(9)
    x = _hp(rng.uniform(-1, 1, n), 2400)
    sig = _norm(x) * (0.85 + 0.15 * np.sin(2 * np.pi * 11 * np.arange(n) / SR))
    return sig * env_ad(n, 0.03, dur * 0.5) * amp

# ---------------------------------------------------------------- 十个意图

def cat_come():   # 咪呜—— 咪呜——（两声上扬的呼唤）
    c = np.zeros(int(0.62 * SR))
    place(c, meow(600, 545, 0.22), 0.00)
    place(c, meow(615, 560, 0.26), 0.30)
    return c, 0.62

def cat_praise(): # 咕噜咕噜～ 咪~
    c = np.zeros(int(1.35 * SR))
    place(c, purr(92, 1.10), 0.0)
    place(c, meow(690, 760, 0.16, amp=0.8), 1.12)
    return c, 1.35

def cat_scold():  # 哈——！嘶……（哈气+低怒）
    c = np.zeros(int(0.60 * SR))
    place(c, hiss(0.26, amp=0.95), 0.0)
    place(c, meow(400, 315, 0.22, bright=0.7), 0.30)
    return c, 0.60

def cat_stop():   # 咔——嘶！
    c = np.zeros(int(0.34 * SR))
    n = int(0.10 * SR)
    kha = tone(0.10, lambda t: np.full_like(t, 520), n_harm=5, tilt=0.6, bright=1.6)
    place(c, kha * env_ad(n, 0.006, 0.06), 0.0)
    place(c, hiss(0.18, amp=0.9), 0.13)
    return c, 0.34

def cat_eat():    # 咪啊～！咪咪咪～（兴奋的三连音）
    c = np.zeros(int(0.72 * SR))
    place(c, meow(640, 705, 0.30, bright=1.15), 0.0)
    place(c, chirp(705, 760, 0.10, amp=0.85), 0.36)
    place(c, chirp(710, 780, 0.10, amp=0.85), 0.50)
    return c, 0.72

def cat_play():   # 咪呜呜～咪！咪！（轻快弹跳）
    c = np.zeros(int(0.55 * SR))
    place(c, meow(660, 770, 0.18, bright=1.2), 0.0)
    place(c, chirp(770, 860, 0.10, amp=0.8), 0.24)
    place(c, chirp(780, 880, 0.10, amp=0.8), 0.38)
    return c, 0.55

def cat_walk():   # 咪~ 咪啊——（一次短一次长的期待）
    c = np.zeros(int(0.90 * SR))
    place(c, meow(560, 625, 0.20, amp=0.9), 0.0)
    place(c, meow(625, 545, 0.52, bright=0.95), 0.30)
    return c, 0.90

def cat_sleep():  # 咕噜……咕噜……（纯低频咕噜）
    c = np.zeros(int(1.60 * SR))
    place(c, purr(85, 1.50, amp=0.9), 0.0)
    return c, 1.60

def cat_comfort(): # 咕噜咕噜～咪……（安定的低喵）
    c = np.zeros(int(1.30 * SR))
    place(c, purr(90, 0.90), 0.0)
    place(c, meow(525, 470, 0.30, amp=0.75, bright=0.85), 0.95)
    return c, 1.30

def cat_talk():   # 咪~咪呜~咕~（友好短句）
    c = np.zeros(int(0.45 * SR))
    place(c, chirp(700, 745, 0.09, amp=0.85), 0.0)
    place(c, meow(620, 665, 0.14, amp=0.9), 0.13)
    place(c, chirp(750, 700, 0.08, amp=0.7), 0.32)
    return c, 0.45

def dog_come():   # 汪！汪汪！
    c = np.zeros(int(0.36 * SR))
    place(c, bark(600, 0.10), 0.0)
    place(c, bark(565, 0.11), 0.16)
    place(c, bark(545, 0.12), 0.28)
    return c, 0.36

def dog_praise(): # 汪呜～（夸奖式上扬）
    c = np.zeros(int(0.50 * SR))
    place(c, bark(620, 0.09), 0.0)
    place(c, whine(500, 780, 0.35), 0.13)
    return c, 0.50

def dog_scold():  # 呜——汪汪汪！（低吼转吠）
    c = np.zeros(int(1.35 * SR))
    place(c, growl(140, 0.65), 0.0)
    place(c, bark(640, 0.10), 0.68)
    place(c, bark(660, 0.09), 0.83)
    place(c, bark(690, 0.12), 0.97)
    return c, 1.35

def dog_stop():   # 汪汪！呜——（两声急停+低警告）
    c = np.zeros(int(0.85 * SR))
    place(c, bark(680, 0.09), 0.0)
    place(c, bark(660, 0.09), 0.13)
    place(c, growl(150, 0.50), 0.28)
    return c, 0.85

def dog_eat():    # 汪汪！咿～（兴奋+期待）
    c = np.zeros(int(0.60 * SR))
    place(c, bark(620, 0.10), 0.0)
    place(c, bark(645, 0.10), 0.14)
    place(c, whine(520, 820, 0.30), 0.28)
    return c, 0.60

def dog_play():   # 汪汪汪！嗷呜～（玩耍邀请）
    c = np.zeros(int(0.95 * SR))
    place(c, bark(640, 0.09), 0.0)
    place(c, bark(650, 0.09), 0.13)
    place(c, bark(660, 0.09), 0.26)
    place(c, howl(260, 430, 330, 0.55), 0.38)
    return c, 0.95

def dog_walk():   # 汪汪汪！嗷呜——！（出门前的兴奋）
    c = np.zeros(int(1.00 * SR))
    place(c, bark(640, 0.09), 0.0)
    place(c, bark(650, 0.09), 0.14)
    place(c, bark(660, 0.09), 0.28)
    place(c, howl(300, 470, 360, 0.60), 0.40)
    return c, 1.00

def dog_sleep():  # 呜……汪……（低柔的困意）
    c = np.zeros(int(0.80 * SR))
    place(c, whine(430, 335, 0.55, amp=0.8), 0.0)
    place(c, bark(240, 0.12, amp=0.55), 0.60)
    return c, 0.80

def dog_comfort(): # 呜～呜……（安抚的低吟）
    c = np.zeros(int(0.85 * SR))
    place(c, whine(465, 380, 0.70, amp=0.85), 0.0)
    return c, 0.85

def dog_talk():   # 汪~ 咿~（友好搭话）
    c = np.zeros(int(0.55 * SR))
    place(c, bark(520, 0.10, amp=0.8), 0.0)
    place(c, bark(560, 0.10, amp=0.8), 0.14)
    place(c, whine(500, 700, 0.26, amp=0.8), 0.28)
    return c, 0.55

# ---------------------------------------------------------------- 输出

CATS = {
    "00_come": cat_come, "01_praise": cat_praise, "02_scold": cat_scold,
    "03_stop": cat_stop, "04_eat": cat_eat, "05_play": cat_play,
    "06_walk": cat_walk, "07_sleep": cat_sleep, "08_comfort": cat_comfort,
    "09_talk": cat_talk,
}
DOGS = {
    "00_come": dog_come, "01_praise": dog_praise, "02_scold": dog_scold,
    "03_stop": dog_stop, "04_eat": dog_eat, "05_play": dog_play,
    "06_walk": dog_walk, "07_sleep": dog_sleep, "08_comfort": dog_comfort,
    "09_talk": dog_talk,
}

def write_wav(path, sig, total):
    n = int(total * SR)
    canvas = np.zeros(n)
    m = min(len(sig), n)
    canvas[:m] = sig[:m]
    # 轻呼吸底噪，避免"死寂感"
    canvas += breath(total, 0.05)
    # 软限幅 + 归一 + 淡出
    canvas = np.tanh(canvas * 1.25)
    canvas = _norm(canvas) * 0.92
    fade = min(int(0.004 * SR), n // 4)
    canvas[:fade] *= np.linspace(0, 1, fade)
    canvas[-fade:] *= np.linspace(1, 0, fade)
    pcm = (canvas * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

def main():
    os.makedirs(OUT, exist_ok=True)
    for species, table in (("cat", CATS), ("dog", DOGS)):
        for name, fn in table.items():
            sig, total = fn()
            path = os.path.join(OUT, f"{species}_{name}.wav")
            write_wav(path, sig, total)
            print(f"OK {os.path.basename(path)}  {total:.2f}s")
    print(f"\n完成：{len(CATS) + len(DOGS)} 条 → {os.path.abspath(OUT)}")

if __name__ == "__main__":
    main()
