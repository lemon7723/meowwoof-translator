#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Freesound 搜索页解析：提取 sound id + 标题（CC0/CC-BY 过滤在 URL 参数里）"""
import os
import re
import sys
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

def fetch(query, license_filter, out):
    url = ("https://freesound.org/search/?q=" + urllib.parse.quote(query)
           + "&f=" + urllib.parse.quote(license_filter))
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    html = urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace")
    ids = list(dict.fromkeys(re.findall(r"/sounds/(\d+)/", html)))
    titles = re.findall(r'title="Listen to ([^"]+)"', html)
    print(f"== {query} ({license_filter[:30]}...): {len(ids)} sounds")
    for i, sid in enumerate(ids[:14]):
        t = titles[i] if i < len(titles) else "?"
        print(f"  {sid} | {t[:60]}")
    out.extend(ids)

if __name__ == "__main__":
    out = []
    fetch("cat meow", 'license:"Creative Commons 0"', out)
    fetch("cat purr", 'license:"Creative Commons 0"', out)
    fetch("dog bark", 'license:"Creative Commons 0"', out)
    fetch("dog whine", 'license:"Creative Commons 0"', out)
    fetch("dog growl", 'license:"Creative Commons 0"', out)
    print("\nALL CC0 IDS:", out)
