#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""下载 Mixkit 选中素材（Mixkit Sound Effects Free License）"""
import os
import subprocess
import sys

TMP = os.environ.get("TEMP", ".")
OUT = os.path.join(os.path.dirname(__file__), "..", "_sfx_raw")
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

PICKS = [
    # cat
    ("86", "cat_hungry_meow"),        # 开饭
    ("92", "cat_sweet_meow"),         # 通用短喵（talk/备用）
    ("95", "cat_attention_meow"),     # 叫它过来
    ("96", "cat_cartoon_meow"),       # 备用
    ("6",  "cat_begging_meow"),       # 玩耍/期待
    ("89", "cat_angry_meow"),         # 骂它
    ("91", "cat_pain_meow"),          # 备用
    ("88", "cat_slow_moan"),          # 睡觉变体素材
    ("45", "cat_long_purr"),          # 安抚（真实咕噜）
    ("308", "cat_purr_growl"),        # 备用
    # dog
    ("60",  "dog_bark_twice"),        # 叫它过来/制止
    ("59",  "dog_happy_puppy"),       # 夸奖/玩耍
    ("466", "dog_annoyed_bark"),      # 制止
    ("741", "dog_angry_bark"),        # 骂它
    ("52",  "dog_whimper_sad"),       # 睡觉/安抚
    ("58",  "dog_whimper2"),          # 安抚
    ("57",  "dog_whimper3"),          # 备用
    ("467", "dog_growl_angry"),       # 骂它变体
    ("620", "dog_growl_aggressive"),  # 备用
    ("50",  "dog_lab_playing"),       # 玩耍
    ("1973", "dog_giant_growl"),      # 备用
]

def main():
    os.makedirs(OUT, exist_ok=True)
    ok = 0
    for sid, name in PICKS:
        dst = os.path.join(OUT, f"{name}_{sid}.mp3")
        if os.path.exists(dst) and os.path.getsize(dst) > 4000:
            ok += 1
            continue
        url = f"https://assets.mixkit.co/active_storage/sfx/{sid}/{sid}-preview.mp3"
        r = subprocess.run(["curl", "-sSL", "--retry", "2", "-A", UA, "-o", dst, url],
                           capture_output=True, text=True)
        size = os.path.getsize(dst) if os.path.exists(dst) else 0
        status = "OK" if size > 4000 else "FAIL"
        if status == "OK":
            ok += 1
        print(f"{status} {sid:>5} {name:<24} {size} bytes")
    print(f"\n{ok}/{len(PICKS)} downloaded -> {os.path.abspath(OUT)}")

if __name__ == "__main__":
    main()
