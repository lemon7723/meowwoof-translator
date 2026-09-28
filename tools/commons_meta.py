#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Wikimedia Commons 素材元数据查询：给定文件名列表，输出 许可/时长/大小/直链"""
import json
import subprocess
import sys
import urllib.parse

UA = "MeowWoofApp/1.0 (asset research)"

FILES = [
    # ---- 猫：喵（多品种多情境变体） ----
    "File:Meow domestic cat.ogg",
    "File:Meow.ogg",
    "File:Audio file of cat meowing.ogg",
    "File:Meow of a pleading cat.oga",
    "File:Meow of a Siamese cat - freemaster2.wav",
    "File:Felis silvestris catus meows.ogg",
    "File:Felis silvestris catus.ogg",
    "File:Maullido de gata hembra joven.ogg",
    "File:Miaulementcornisg.ogg",
    "File:GettingOutImpatient.ogg",
    "File:NoTrip.ogg",
    "File:2015-11-24.νιαούρισμα.Νιάου.noise reduced.flac",
    # ---- 猫：咕噜 ----
    "File:Purring cat.oga",
    "File:Purring cat bertie.ogg",
    "File:Bachgasse Wiki Lina Gebhardt and Anna Muck Cats Purring - Katzenschnurren.ogg",
    "File:Purring and meowing.ogg",
    # ---- 狗：吠 ----
    "File:Barking of a dog.ogg",
    "File:Barking of a dog 2.ogg",
    "File:Perro ladrando.ogg",
    "File:Rottweiler Barking.oga",
    "File:De-bellen.ogg",
    "File:Seis perros ladrando.wav",
    "File:Dog barking.webm",
    # ---- 狗：低吼（含研究录音） ----
    "File:Dogs'-Expectation-about-Signalers'-Body-Size-by-Virtue-of-Their-Growls-pone.0015175.s006.ogg",
    "File:Dogs'-Expectation-about-Signalers'-Body-Size-by-Virtue-of-Their-Growls-pone.0015175.s007.ogg",
    # ---- 狗：嚎 ----
    "File:Jem howls.ogg",
]

def main():
    titles = "|".join(FILES)
    url = ("https://commons.wikimedia.org/w/api.php?action=query&titles="
           + urllib.parse.quote(titles)
           + "&prop=imageinfo&iiprop=url|size|extmetadata&format=json")
    out = subprocess.run(["curl", "-sSL", "--max-time", "30", "-A", UA, url],
                         capture_output=True, text=True)
    d = json.loads(out.stdout)
    pages = d.get("query", {}).get("pages", {})
    for pid, page in pages.items():
        title = page.get("title", "?")
        infos = page.get("imageinfo")
        if not infos:
            print(f"MISSING | {title}")
            continue
        info = infos[0]
        em = info.get("extmetadata", {})
        lic = em.get("LicenseShortName", {}).get("value", "?")
        dur = em.get("Duration", {}).get("value", "?")
        author = em.get("Artist", {}).get("value", "?")[:40]
        print(f"{title} | lic={lic} | dur={dur}s | size={info.get('size', 0)} | by={author}")
        print(f"   url={info.get('url')}")

if __name__ == "__main__":
    main()
