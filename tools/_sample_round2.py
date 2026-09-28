#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Freesound CC0 定向补采第二轮：开饭喵 / 狗安抚音（叹气、哈欠、轻哼）。
带总时限下载，逐条写 index（防中断丢账）。"""
import json
import os
import re
import socket
import subprocess
import time
import urllib.parse
import urllib.request

socket.setdefaulttimeout(25)
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "_sfx_raw3")
SR = 22050

QUERIES = {
    "foodmeow": ["cat meow food", "cat begging meow"],
    "sigh": ["dog sigh", "dog sighing relax"],
    "yawn": ["dog yawn", "puppy yawn"],
    "dogmurmur": ["dog murmuring", "dog grumble comfortable"],
}


def http(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=25).read()


def fetch(url, dst, budget=30):
    t0 = time.time()
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as r, open(dst, "wb") as f:
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            if time.time() - t0 > budget:
                raise TimeoutError("slow")
            f.write(chunk)


def search_ids(query, limit=8):
    f = 'license:"Creative Commons 0"'
    url = ("https://freesound.org/search/?q=" + urllib.parse.quote(query)
           + "&f=" + urllib.parse.quote(f))
    return list(dict.fromkeys(
        re.findall(r"/sounds/(\d+)/", http(url).decode("utf-8", "replace"))))[:limit]


def sound_meta(sid):
    html = http(f"https://freesound.org/s/{sid}/").decode("utf-8", "replace")
    title = re.search(r"<title>([^<]+)</title>", html)
    dl = re.search(r'(https://cdn\.freesound\.org/previews/[^"]+\.mp3)', html)
    return (title.group(1).strip() if title else "?",
            dl.group(1) if dl else None)


def main():
    idx_path = os.path.join(OUT, "index.json")
    index = {}
    if os.path.exists(idx_path):
        try:
            index = json.load(open(idx_path, encoding="utf-8"))
        except Exception:
            index = {}
    for tag, queries in QUERIES.items():
        n = 0
        for q in queries:
            if n >= 3:
                break
            try:
                ids = search_ids(q)
            except Exception as e:
                print(f"[{tag}] search '{q}' failed: {e}", flush=True)
                continue
            for sid in ids:
                if n >= 3:
                    break
                name = f"{tag}_{sid}"
                wav = os.path.join(OUT, name + ".wav")
                if os.path.exists(wav) or name in index:
                    continue
                try:
                    title, url = sound_meta(sid)
                    if not url:
                        continue
                    mp3 = wav.replace(".wav", ".mp3")
                    fetch(url, mp3)
                    subprocess.run(
                        ["ffmpeg", "-v", "error", "-y", "-i", mp3,
                         "-ac", "1", "-ar", str(SR), wav], check=True)
                    os.remove(mp3)
                    index[name] = f"Freesound - {title}"
                    json.dump(index, open(idx_path, "w", encoding="utf-8"),
                              ensure_ascii=False, indent=1)
                    print(f"  +{name}  ({title[:40]})", flush=True)
                    n += 1
                except Exception as e:
                    print(f"[{name}] failed: {e}", flush=True)
        print(f"[{tag}] done +{n}", flush=True)


if __name__ == "__main__":
    main()
