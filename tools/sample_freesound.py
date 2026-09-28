#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Freesound CC0 采样器：
1) 按查询词抓搜索页拿 sound id 列表（CC0 过滤）
2) 逐个抓声音详情页拿 MP3 预览直链 + 标题 + 时长
3) 下载预览 MP3 到 _sfx_raw3/ 并转码 22050Hz WAV
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "_sfx_raw3")
SR = 22050

def http(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=30).read()

def search_ids(query, limit=10):
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
    dur = re.search(r"([\d.]+)\s*(?:seconds|s)\b", html)
    return {
        "id": sid,
        "title": title.group(1).strip() if title else "?",
        "url": dl.group(1) if dl else None,
    }

def main():
    os.makedirs(OUT, exist_ok=True)
    queries = {
        "meow": "cat meow",
        "meow2": "kitten meow",
        "purr": "cat purr",
        "hiss": "cat hiss",
        "bark": "dog bark",
        "bark2": "puppy bark",
        "whine": "dog whine",
        "growl": "dog growl",
        "howl": "dog howl",
    }
    index = {}
    for tag, q in queries.items():
        ids = search_ids(q, limit=8)
        print(f"== {q}: {len(ids)} ids")
        got = 0
        for sid in ids:
            if got >= 5:
                break
            wav_path = os.path.join(OUT, f"{tag}_{sid}.wav")
            if os.path.exists(wav_path):
                got += 1
                continue
            try:
                meta = sound_meta(sid)
                if not meta["url"]:
                    print(f"  SKIP {sid} (no preview link)")
                    continue
                raw = os.path.join(OUT, f"{tag}_{sid}.mp3")
                data = http(meta["url"])
                with open(raw, "wb") as fh:
                    fh.write(data)
                r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", raw,
                                    "-ac", "1", "-ar", str(SR), wav_path],
                                   capture_output=True, text=True)
                os.remove(raw)
                if r.returncode == 0 and os.path.getsize(wav_path) > 3000:
                    got += 1
                    index[f"{tag}_{sid}"] = meta["title"]
                    print(f"  OK {tag}_{sid} | {meta['title'][:55]}")
                else:
                    print(f"  FF-FAIL {sid}")
            except Exception as e:
                print(f"  ERR {sid}: {str(e)[:60]}")
    with open(os.path.join(OUT, "index.json"), "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=1)
    print(f"\nsampled files -> {OUT}")

if __name__ == "__main__":
    main()
