#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""下载 Commons 选中素材 -> 解码为 22050Hz f32 原始数据暂存 _sfx_raw2/"""
import os
import subprocess

UA = "MeowWoofApp/1.0 (asset research)"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "_sfx_raw2")
SR = 22050

ITEMS = {
    # ---- 猫：喵（不同个体/情境/品种） ----
    "meow_greek_nr": "https://upload.wikimedia.org/wikipedia/commons/7/74/2015-11-24.%CE%BD%CE%B9%CE%B1%CE%BF%CF%8D%CF%81%CE%B9%CF%83%CE%BC%CE%B1.%CE%9D%CE%B9%CE%AC%CE%BF%CF%85.noise_reduced.flac",
    "meow_audio_file": "https://upload.wikimedia.org/wikipedia/commons/9/9c/Audio_file_of_cat_meowing.ogg",
    "meow_pleading": "https://upload.wikimedia.org/wikipedia/commons/6/6b/Meow_of_a_pleading_cat.oga",
    "meow_siamese": "https://upload.wikimedia.org/wikipedia/commons/8/81/Meow_of_a_Siamese_cat_-_freemaster2.wav",
    "meow_female": "https://upload.wikimedia.org/wikipedia/commons/c/c0/Maullido_de_gata_hembra_joven.ogg",
    "meow_plaintive": "https://upload.wikimedia.org/wikipedia/commons/6/62/Meow.ogg",
    "meow_hungry_want": "https://upload.wikimedia.org/wikipedia/commons/1/19/Miaulementcornisg.ogg",
    "meow_impatient": "https://upload.wikimedia.org/wikipedia/commons/c/c0/GettingOutImpatient.ogg",
    "meow_notrip": "https://upload.wikimedia.org/wikipedia/commons/d/d1/NoTrip.ogg",
    "meow_series": "https://upload.wikimedia.org/wikipedia/commons/5/53/Felis_silvestris_catus_meows.ogg",
    "meow_single": "https://upload.wikimedia.org/wikipedia/commons/3/31/Felis_silvestris_catus.ogg",
    # ---- 猫：咕噜 ----
    "purr_cat": "https://upload.wikimedia.org/wikipedia/commons/d/db/Purring_cat.oga",
    "purr_bertie": "https://upload.wikimedia.org/wikipedia/commons/6/69/Purring_cat_bertie.ogg",
    "purr_purring_meowing": "https://upload.wikimedia.org/wikipedia/commons/e/e6/Purring_and_meowing.ogg",
    "purr_katzenschnurren": "https://upload.wikimedia.org/wikipedia/commons/4/46/Bachgasse_Wiki_Lina_Gebhardt_and_Anna_Muck_Cats_Purring_-_Katzenschnurren.ogg",
    # ---- 狗：吠 ----
    "bark_single": "https://upload.wikimedia.org/wikipedia/commons/a/a2/Barking_of_a_dog.ogg",
    "bark_single2": "https://upload.wikimedia.org/wikipedia/commons/5/58/Barking_of_a_dog_2.ogg",
    "bark_perro": "https://upload.wikimedia.org/wikipedia/commons/1/1c/Perro_ladrando.ogg",
    "bark_rottweiler": "https://upload.wikimedia.org/wikipedia/commons/b/b6/Rottweiler_Barking.oga",
    "bark_de": "https://upload.wikimedia.org/wikipedia/commons/8/83/De-bellen.ogg",
    "bark_dogs_series": "https://upload.wikimedia.org/wikipedia/commons/e/e0/Seis_perros_ladrando.wav",
    "bark_webm": "https://upload.wikimedia.org/wikipedia/commons/b/be/Dog_barking.webm",
    # ---- 狗：低吼（Faragó et al. 2017 研究录音，CC BY 2.5） ----
    "growl_a": "https://upload.wikimedia.org/wikipedia/commons/5/5d/Dogs%27-Expectation-about-Signalers%27-Body-Size-by-Virtue-of-Their-Growls-pone.0015175.s006.ogg",
    "growl_b": "https://upload.wikimedia.org/wikipedia/commons/4/44/Dogs%27-Expectation-about-Signalers%27-Body-Size-by-Virtue-of-Their-Growls-pone.0015175.s007.ogg",
    # ---- 狗：嚎 ----
    "howl_jem": "https://upload.wikimedia.org/wikipedia/commons/c/c2/Jem_howls.ogg",
}

def main():
    os.makedirs(OUT, exist_ok=True)
    ok = 0
    for name, url in ITEMS.items():
        raw = os.path.join(OUT, name + ".bin")
        wav = os.path.join(OUT, name + ".wav")
        if os.path.exists(wav) and os.path.getsize(wav) > 4000:
            ok += 1
            continue
        # download original
        r = subprocess.run(["curl", "-sSL", "--retry", "2", "-A", UA,
                            "-o", raw, url], capture_output=True, text=True)
        if not os.path.exists(raw) or os.path.getsize(raw) < 2000:
            print(f"FAIL-DL {name}")
            continue
        # transcode to wav 22050 mono
        r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", raw,
                            "-ac", "1", "-ar", str(SR), wav],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(wav) or os.path.getsize(wav) < 4000:
            print(f"FAIL-FF {name}: {r.stderr[:100]}")
            continue
        os.remove(raw)
        ok += 1
        print(f"OK {name} {os.path.getsize(wav)} bytes")
    print(f"\n{ok}/{len(ITEMS)} -> {os.path.abspath(OUT)}")

if __name__ == "__main__":
    main()
