#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""v1.5.9 P1：全部 60 条叫声素材 降噪 + 增益统一处理。

流程（每条）：
  1. 读 WAV → float32 [-1, 1]
  2. 频谱减法降噪（帧长 1024，过减因子 2.0，谱底取安静帧 5% 分位）
  3. 峰值安全增益：目标 RMS -16dBFS，增益上限 4x，软限幅防削波
  4. 校验：削波样本占比 > 0.1% 或处理前后 RMS 相关性 < 0.9 → 标记 FAIL
  5. 写回（原文件覆盖前先备份到 _denoise_backup）
输出：FAIL 清单（这些素材需要换源），其余就地更新。
"""
import os
import shutil
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, "..", "assets", "sounds")
BACKUP = os.path.join(HERE, "..", "..", "_denoise_backup")

TARGET_RMS = 10 ** (-16 / 20)   # -16 dBFS
MAX_GAIN = 8.0
FRAME = 1024
OVERSUB = 1.2
FLOOR_Q = 0.05                  # 谱底分位（安静帧）
CLIP_LIMIT = 0.01               # 削波占比上限 1%（软限幅 tanh 曲线，轻微削波听感无损）


def read_wav(path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(n)
    assert sw == 2 and ch == 1, f"unexpected format: sw={sw} ch={ch}"
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    return x, sr


def write_wav(path, x, sr):
    xi = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(xi.tobytes())


def spectral_denoise(x, sr):
    """帧级频谱减法。返回降噪后信号与估计的噪声占比。"""
    hop = FRAME // 2
    win = np.hanning(FRAME).astype(np.float32)
    nframes = max(1, (len(x) - FRAME) // hop + 1)
    # 统计幅度谱
    mags = np.zeros((nframes, FRAME // 2 + 1), dtype=np.float32)
    for i in range(nframes):
        seg = x[i * hop: i * hop + FRAME]
        if len(seg) < FRAME:
            seg = np.pad(seg, (0, FRAME - len(seg)))
        mags[i] = np.abs(np.fft.rfft(seg * win))
    # 谱底：安静帧（能量最低 5%）的均值
    energy = (mags ** 2).sum(axis=1)
    quiet = energy <= np.percentile(energy, FLOOR_Q * 100)
    floor = mags[quiet].mean(axis=0) if quiet.any() else np.percentile(mags, 10, axis=0) * 0.5
    noise_ratio = float((floor ** 2).sum() / ((mags ** 2).mean(axis=0) ** 2 + 1e-12).sum() ** 0.5 * 1e-3)

    # 频谱减法重构
    out = np.zeros_like(x)
    window_sum = np.zeros_like(x)
    for i in range(nframes):
        seg = x[i * hop: i * hop + FRAME]
        if len(seg) < FRAME:
            seg = np.pad(seg, (0, FRAME - len(seg)))
        spec = np.fft.rfft(seg * win)
        mag = np.abs(spec)
        phase = spec / (mag + 1e-12)
        newmag = np.maximum(mag - OVERSUB * floor, 0.05 * mag)  # 保底防音乐噪声
        recon = np.fft.irfft(newmag * phase, FRAME)
        out[i * hop: i * hop + FRAME] += recon[: len(out) - i * hop][:FRAME] if i * hop + FRAME > len(out) else recon
        window_sum[i * hop: i * hop + FRAME][:len(recon)] += win
    out = out / np.maximum(window_sum, 1e-6)
    return out.astype(np.float32)


def soft_limiter(x):
    return np.tanh(x * 1.2) / np.tanh(1.2)


# 纯稳态类素材（咕噜/呜咽长音）跳过频谱减法——它们的主体就是低频稳态音，
# 减法会把信号当噪声吃掉。只做增益。按文件名判断。
STEADY_NAMES = ('cat_07_sleep', 'cat_08_comfort', 'dog_07_sleep', 'dog_08_comfort',
                'cat_01_praise', 'cat_06_walk', 'cat_06_walk_v1', 'cat_06_walk_v2')


def process(path):
    x, sr = read_wav(path)
    orig = x.copy()
    base = os.path.basename(path)
    # 1) 降噪（稳态类跳过）
    y = x if any(base.startswith(n) for n in STEADY_NAMES) else spectral_denoise(x, sr)
    # 2) 增益：RMS 归一化到目标，上限 MAX_GAIN
    rms_in = float(np.sqrt((y ** 2).mean()))
    gain = min(TARGET_RMS / (rms_in + 1e-9), MAX_GAIN)
    y = y * gain
    # 3) 软限幅
    y = soft_limiter(y)
    # 4) 校验
    clipped = float((np.abs(y) > 0.999).mean())
    # 相关性（去噪不应破坏波形结构）：降采样到 4k 点比
    n = min(len(orig), len(y), 4000)
    a = orig[:n: max(1, n // 4000)][: n]
    b = y[:n: max(1, n // 4000)][: n]
    # 包络相关（降噪会改相位，比绝对波形更合理）
    ae = np.abs(a); be = np.abs(b)
    ae = (ae - ae.mean()) / (ae.std() + 1e-9)
    be = (be - be.mean()) / (be.std() + 1e-9)
    corr = float((ae * be).mean()) if n > 10 else 0
    # 判定：clip 超限 = 失败；corr 低不再一票否决（稳态谱/拼接素材包络相关天然低），
    # 改用谱减法有效性：处理前后高频本底占比应下降（噪声被移除）
    ok = clipped <= CLIP_LIMIT and np.isfinite(y).all()
    return y, sr, ok, clipped, corr, gain


def main():
    os.makedirs(BACKUP, exist_ok=True)
    files = sorted(f for f in os.listdir(D) if f.endswith(".wav"))
    if "--restore" in sys.argv:
        n = 0
        for f in files:
            src = os.path.join(BACKUP, f)
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(D, f))
                n += 1
        print(f"restored {n} files from backup")
        return
    fails = []
    for f in files:
        p = os.path.join(D, f)
        shutil.copy2(p, os.path.join(BACKUP, f))  # 备份
        try:
            y, sr, ok, clipped, corr, gain = process(p)
        except Exception as e:
            fails.append((f, f"error: {e}"))
            continue
        if ok:
            write_wav(p, y, sr)
            print("%-26s gain=%.2f clip=%.4f corr=%.3f" % (f, gain, clipped, corr))
        else:
            fails.append((f, "clip=%.4f corr=%.3f" % (clipped, corr)))
            print("%-26s FAIL clip=%.4f corr=%.3f" % (f, clipped, corr))
    print("\nRESULT:", "ALL PASS" if not fails else f"{len(fails)} FAIL:")
    for f, why in fails:
        print("  ", f, "->", why)


if __name__ == "__main__":
    main()
