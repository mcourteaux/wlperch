#!/usr/bin/env python3
"""Subset the Nerd Fonts symbol font to the icons wlperch uses.

wlperch embeds the symbol font (#load in src/theme.odin); the full font is
~2.4 MB for ~10k icons, of which wlperch uses a few hundred. This keeps only
the codepoints that appear in src/*.odin (\\uXXXX / \\UXXXXXXXX escapes and
literal private-use characters).

Run after adding an icon (test_symbol_font_has_icons fails until you do):
    python3 tools/subset_symbols.py
Needs fontTools (pip install fonttools).
"""
import glob
import os
import re
import sys

from fontTools import subset

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets/fonts/SymbolsNerdFont-Regular.ttf")
OUT = os.path.join(ROOT, "assets/fonts/SymbolsNerdFont-Subset.ttf")


def is_icon(cp):
    return 0xE000 <= cp <= 0xF8FF or 0xF0000 <= cp <= 0x10FFFF


def used_codepoints():
    cps = set()
    for path in glob.glob(os.path.join(ROOT, "src", "*.odin")):
        text = open(path, encoding="utf-8").read()
        cps.update(int(h, 16) for h in re.findall(r"\\U([0-9A-Fa-f]{8})", text))
        cps.update(int(h, 16) for h in re.findall(r"\\u([0-9A-Fa-f]{4})", text))
        cps.update(ord(ch) for ch in text if is_icon(ord(ch)))
    return sorted(cp for cp in cps if is_icon(cp))


def main():
    cps = used_codepoints()
    opts = subset.Options()
    opts.layout_features = []
    opts.name_IDs = ["*"]  # keep the copyright / licence names
    opts.notdef_outline = True
    font = subset.load_font(SRC, opts)
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=cps)
    sub.subset(font)
    subset.save_font(font, OUT, opts)
    print(f"{len(cps)} icons -> {os.path.relpath(OUT, ROOT)} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    sys.exit(main())
