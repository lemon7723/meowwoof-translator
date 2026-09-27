#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""列出全部已抓 Mixkit 页面的素材：页面 | id | 标题 | 时长"""
import os
import glob
import re

def parse(path):
    html = open(path, encoding="utf-8", errors="replace").read()
    out = {}
    for m in re.finditer(r"active_storage/sfx/(\d+)/\1-preview\.mp3", html):
        sid = m.group(1)
        if sid in out:
            continue
        seg = html[max(0, m.start() - 2600):m.start()]
        t = re.search(r'item-grid-card__title">\s*([^<]+?)\s*</h2>', seg)
        d = re.findall(r'data-test-id="duration">\s*([0-9:]+)\s*<', seg)
        out[sid] = (t.group(1) if t else "?", d[-1] if d else "?")
    return out

def main():
    tmp = os.environ.get("TEMP", ".")
    files = sorted(glob.glob(os.path.join(tmp, "mixkit_*.html")))
    seen = {}
    for f in files:
        tag = os.path.basename(f).replace("mixkit_", "").replace(".html", "")
        for sid, (title, dur) in parse(f).items():
            seen.setdefault(sid, (title, dur, tag))
    for sid in sorted(seen, key=int):
        title, dur, tag = seen[sid]
        print(f"{sid:>5} | {dur:>5} | {tag:<8} | {title}")

if __name__ == "__main__":
    main()
