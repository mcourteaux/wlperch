#!/usr/bin/env python3
"""Helpers for release.sh's Debian sysroot (stdlib only; run with python3 -I).

  debian.py select RELEASE INDEX_PATH INDEX_FILE PKG...
      Check INDEX_FILE (a Packages.xz) against the SHA256 that the Release
      file RELEASE lists for INDEX_PATH (e.g. main/binary-amd64/Packages.xz),
      then print one line per package: "Filename SHA256 Size Version".
      Fails if a package is missing.

  debian.py fix-symlinks ROOT
      Rewrite absolute symlinks under ROOT (e.g. /lib/x86_64-linux-gnu/libz.so.1)
      as relative ones that stay inside ROOT, so the sysroot is relocatable
      and never points into the build machine's own /lib.
"""
import hashlib
import lzma
import os
import sys


def die(msg):
    print("debian.py: " + msg, file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def release_sha256(release, want_path):
    in_sha256 = False
    with open(release, encoding="utf-8") as f:
        for line in f:
            if not line.startswith(" "):
                in_sha256 = line.startswith("SHA256:")
                continue
            if in_sha256:
                parts = line.split()
                if len(parts) == 3 and parts[2] == want_path:
                    return parts[0], int(parts[1])
    die(f"{want_path} is not listed under SHA256 in {release}")


def parse_index(data):
    """Yield one dict per stanza of a Packages file."""
    cur = {}
    key = None
    for line in data.splitlines():
        if not line:
            if cur:
                yield cur
            cur, key = {}, None
        elif line[0] in " \t":
            if key:
                cur[key] += "\n" + line
        elif ":" in line:
            key, val = line.split(":", 1)
            cur[key] = val.strip()
    if cur:
        yield cur


def cmd_select(release, index_path, index_file, pkgs):
    want_hash, want_size = release_sha256(release, index_path)
    if os.path.getsize(index_file) != want_size or sha256_file(index_file) != want_hash:
        die(f"{index_file} does not match the Release entry for {index_path}")
    data = lzma.decompress(open(index_file, "rb").read()).decode("utf-8", "replace")
    wanted = set(pkgs)
    found = {}
    for st in parse_index(data):
        name = st.get("Package")
        if name in wanted:
            if name in found and found[name]["Version"] != st["Version"]:
                die(f"{name} has more than one version in the index")
            found[name] = st
    missing = sorted(wanted - found.keys())
    if missing:
        die("not in the index: " + " ".join(missing))
    for name in sorted(found):
        st = found[name]
        for k in ("Filename", "SHA256", "Size", "Version"):
            if k not in st:
                die(f"{name}: no {k} field")
        if "/" not in st["Filename"] or ".." in st["Filename"].split("/"):
            die(f"{name}: odd Filename {st['Filename']!r}")
        print(st["Filename"], st["SHA256"], st["Size"], st["Version"])


def cmd_fix_symlinks(root):
    root = os.path.realpath(root)
    fixed = 0
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            if not os.path.islink(p):
                continue
            target = os.readlink(p)
            if not target.startswith("/"):
                continue
            # Relative to where the link really lives (lib -> usr/lib etc.).
            real_dir = os.path.realpath(dirpath)
            rel = os.path.relpath(root + target, real_dir)
            os.unlink(p)
            os.symlink(rel, p)
            fixed += 1
    print(f"made {fixed} absolute symlinks relative")


def main(argv):
    if len(argv) >= 5 and argv[1] == "select":
        cmd_select(argv[2], argv[3], argv[4], argv[5:])
    elif len(argv) == 3 and argv[1] == "fix-symlinks":
        cmd_fix_symlinks(argv[2])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
