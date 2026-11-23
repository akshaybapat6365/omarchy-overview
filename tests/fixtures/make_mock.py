#!/usr/bin/env python3
"""Writes tests/fixtures/mock/fixture.json: the mock desktops every lane tests against.

Neutral on purpose: no real titles, names, places or folders. Pictures live in
mock/pics (docs and editor are stills of public pages and this project's code;
terminal, notes and media are generated plates). Each window gets the picture of
its kind whose aspect is closest to its own; the mock crops the rest.

Scenarios (monitor 2400x1500 logical, bar 26, gaps 12, like his laptop):
  one       1 desk, 2 windows
  six       6 desks, active 3 (5 windows, dwindle)
  nine      9 desks, active 5
  thirteen  13 desks, active 7 (strip has to scroll)
  many      desk 2 holds 14 windows (grid stress), active 2
  empty     desks 1-4 hold windows, active desk 5 is empty
  gap       desks 1 2 3 5 6 hold windows, desk 4 is empty (his desktop on 2026-11-19), active 3
Run: python3 tests/fixtures/make_mock.py   (stdlib only, deterministic)
"""
import json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
MOCK = os.path.join(HERE, "mock")
X0, Y0, W, H, G = 12, 38, 2376, 1450, 12

KINDS = {  # kind: (class, title)
    "docs":     ("chromium", "Documentation – Chromium"),
    "editor":   ("dev.zed.Zed", "Layout.js — Zed"),
    "terminal": ("com.mitchellh.ghostty", "Terminal"),
    "notes":    ("org.gnome.TextEditor", "Stage notes"),
    "media":    ("org.gnome.Loupe", "Gradient.png"),
}
CYCLE = ["terminal", "docs", "editor", "notes", "media"]

def pictures():
    out = {}
    for f in sorted(os.listdir(os.path.join(MOCK, "pics"))):
        m = re.match(r"([a-z]+)-(\d+)x(\d+)\.png$", f)
        if m: out.setdefault(m.group(1), []).append((int(m.group(2)) / int(m.group(3)), f))
    return out
PICS = pictures()
def picture(kind, w, h):
    a = w / h
    return min(PICS[kind], key=lambda p: abs(p[0] - a))[1]

def full(): return [(X0, Y0, W, H)]
def halves():
    w = (W - G) // 2
    return [(X0, Y0, w, H), (X0 + w + G, Y0, W - w - G, H)]
def dwindle(n):
    out, x, y, w, h, vertical = [], X0, Y0, W, H, True
    for i in range(n):
        if i == n - 1: out.append((x, y, w, h)); break
        if vertical: a = (w - G) // 2; out.append((x, y, a, h)); x, w = x + a + G, w - a - G
        else: a = (h - G) // 2; out.append((x, y, w, a)); y, h = y + a + G, h - a - G
        vertical = not vertical
    return out
def grid(cols, rows, n=None):
    cw, rh = (W - G * (cols - 1)) // cols, (H - G * (rows - 1)) // rows
    r = [(X0 + c * (cw + G), Y0 + j * (rh + G), cw, rh) for j in range(rows) for c in range(cols)]
    return r[: n or len(r)]

def simple(n_desks, rich=None):
    """One window per desk; desks in `rich` get a layout of their own."""
    rich = rich or {}
    return [(d, rich.get(d, full())) for d in range(1, n_desks + 1)]

SCEN = {
    "one":      dict(active=1, desks=[(1, halves())]),
    "six":      dict(active=3, desks=simple(6, {3: dwindle(5), 4: halves()})),
    "nine":     dict(active=5, desks=simple(9, {5: dwindle(4), 2: halves()})),
    "thirteen": dict(active=7, desks=simple(13, {7: dwindle(3)})),
    "many":     dict(active=2, desks=[(1, full()), (2, grid(5, 3, 14)), (3, halves())]),
    "empty":    dict(active=5, desks=[(1, full()), (2, halves()), (3, full()), (4, dwindle(3))]),
    "gap":      dict(active=3, desks=[(1, full()), (2, halves()), (3, dwindle(3)), (5, full()), (6, halves())]),
}

def main():
    out = {"monitor": [2400, 1500], "scenarios": {}}
    for si, (name, sc) in enumerate(SCEN.items()):
        wins, rank, k = [], 0, si
        for desk, rects in sc["desks"]:
            for (x, y, w, h) in rects:
                kind = CYCLE[k % len(CYCLE)]; k += 1
                cls, title = KINDS[kind]
                wins.append(dict(id="0x%x%03x" % (0xa + si, len(wins)), desk=desk, x=x, y=y, w=w, h=h,
                                 appClass=cls, title=title, picture=picture(kind, w, h), focusRank=rank))
                rank += 1
        out["scenarios"][name] = dict(active=sc["active"], windows=wins)
    with open(os.path.join(MOCK, "fixture.json"), "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print({k: (len(v["windows"]), len({w["desk"] for w in v["windows"]})) for k, v in out["scenarios"].items()})

if __name__ == "__main__":
    main()
