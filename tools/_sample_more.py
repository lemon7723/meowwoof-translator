#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Freesound CC0 补采：按参考板风格清单扩充 _sfx_raw3 源池。
每条只取尚未下载的 id，转换 22050Hz WAV，并把作者/标题并入 index.json。"""
import json
import os
import re
import socket
import subprocess
import urllib.parse
import urllib.request

socket.setdefaulttimeout(25)  # 全局超时（含 urlretrieve）

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "_sfx_raw3")
SR = 22050

# 参考板风格 → 补采查询（全部限定 CC0）
QUERIES = {
    "chirp": "cat chirping",
    "trill": "cat trill",
    "kitten2": "kitten mewing",
    "plaintive": "cat meow sad",
    "grumpy": "angry cat meow",
    "purr2": "cat purring",
    "puppy": "puppy yelp",
    "whine2": "dog whining",
    "smallbark": "small dog bark",
    "deepbark": "deep dog bark",
    "howl2": "dog howl",
    "playgrowl": "dog growl playing",
}


def http(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=30).read()


def fetch(url, dst, budget=25):
    """带总时限的下载：慢速滴流也会在 budget 秒内被中断"""
    import time
    t0 = time.time()
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as r, open(dst, "wb") as f:
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            if time.time() - t0 > budget:
                raise TimeoutError(f"slow download: {url}")
            f.write(chunk)


def search_ids(query, limit=6):
    f = 'license:"Creative Commons 0"'
    url = ("https://freesound.org/search/?q=" + urllib.parse.quote(query)
           + "&f=" + urllib.parse.quote(f))
    html = http(url).decode("utf-8", "replace")
    return list(dict.fromkeys(re.findall(r"/sounds/(\d+)/", html)))[:limit]


def sound_meta(sid):
    url = f"https://freesound.org/s/{sid}/"
    html = http(url).decode("utf-8", "replace")
    title = re.search(r"<title>([^<]+)</title>", html)
    dl = re.search(r'(https://cdn\.freesound\.org/previews/[^"]+\.mp3)', html)
    by = re.search(r"by ([^<]+)</a>", html)
    return {
        "title": title.group(1).strip() if title else "?",
        "url": dl.group(1) if dl else None,
        "by": by.group(1).strip() if by else "?",
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    idx_path = os.path.join(OUT, "index.json")
    index = {}
    if os.path.exists(idx_path):
        try:
            index = json.load(open(idx_path, encoding="utf-8"))
        except Exception:
            index = {}
    added = []
    for tag, q in QUERIES.items():
        try:
            ids = search_ids(q)
        except Exception as e:
            print(f"[{tag}] search failed: {e}")
            continue
        n = 0
        for sid in ids:
            name = f"{tag}_{sid}"
            wav = os.path.join(OUT, name + ".wav")
            if os.path.exists(wav):
                continue
            try:
                meta = sound_meta(sid)
                if not meta["url"]:
                    continue
                mp3 = os.path.join(OUT, name + ".mp3")
                if not os.path.exists(mp3):
                    fetch(meta["url"], mp3)
                subprocess.run(
                    ["ffmpeg", "-v", "error", "-y", "-i", mp3,
                     "-ac", "1", "-ar", str(SR), wav], check=True)
                index[name] = f"Freesound - {meta['title']} by {meta['by']}"
                os.remove(mp3)
                added.append(name)
                n += 1
                if n >= 3:
                    break
            except Exception as e:
                print(f"[{name}] failed: {e}", flush=True)
        print(f"[{tag}] +{n}", flush=True)
    json.dump(index, open(idx_path, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("added:", len(added))
    for a in added:
        print(" ", a)


if __name__ == "__main__":
    main()
