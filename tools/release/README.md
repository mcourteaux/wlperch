# Release builds

`tools/release/release.sh` builds the release tarballs of wlperch for x86_64
and aarch64 Linux. It works on any x86_64 (or aarch64) Linux machine without
root, downloads every input it needs, checks each download against a hash in
[`pins.env`](pins.env), and produces bit-identical output on every run.

| File | What it is |
| --- | --- |
| `release.sh` | the build: fetch, sysroot, compile, check, package, (publish) |
| `pins.env` | pinned versions and SHA256s of every input; the release requirements |
| `debian.py` | helper for the Debian sysroot: reads Packages indexes, fixes symlinks |

## Prerequisites

| Tool | Fedora | Debian / Ubuntu |
| --- | --- | --- |
| clang, clang++ | `clang` | `clang` |
| ld.lld | `lld` | `lld` |
| llvm-ar (or `ar`) | `llvm` | `llvm` |
| readelf, strings (and `ar`) | `binutils` | `binutils` |
| git, curl, tar, gzip, file | `git curl tar gzip file` | `git curl tar gzip file` |
| xz (only without `dpkg-deb`) | `xz` | `xz-utils` |
| python3 | `python3` | `python3` |
| gpgv (optional, signature check) | `gnupg2` | `gpgv` |
| gh (only for `--publish`) | `gh` | `gh` |

```sh
sudo dnf install clang lld llvm binutils git curl tar gzip file xz python3 gnupg2   # Fedora
sudo apt install clang lld llvm binutils git curl tar gzip file xz-utils python3 gpgv # Debian/Ubuntu
```

Nothing else is needed: not Odin, not the Wayland or FreeType development
files, not a cross toolchain, not qemu. Everything else comes from the pins.

## Usage

```sh
tools/release/release.sh                  # both arches -> build/release/
tools/release/release.sh --arch arm64     # one arch
tools/release/release.sh --version-check  # what a real release does: clean tree, HEAD tagged v<VERSION>
tools/release/release.sh --publish        # build, then create the GitHub release (asks first)
tools/release/release.sh --help
```

The output is `wlperch-<version>-<x86_64|aarch64>-linux.tar.gz` (one top folder
of the same name holding `wlperch`, `README.md`, `contrib/` and `licenses/`)
and `SHA256SUMS`, in `--out` (default `build/release/`). The version is
`VERSION :: "x.y.z"` in `src/main.odin`.

What a run does:

1. Clones the repository's **HEAD** (not the working tree: uncommitted changes
   are never in a release) into the build root, `/tmp/wlperch-release-build`.
2. Fetches the pinned inputs into the cache,
   `${XDG_CACHE_HOME:-~/.cache}/wlperch-release` (`--cache`). A warm cache makes
   a run network-free. The build root is deleted after a successful run
   (`--keep-build` keeps it).
3. Per arch: builds a Debian 12 sysroot, unpacks Odin and rebuilds its `stb`
   libraries for the target, builds Dear ImGui (with FreeType, 32-bit
   `ImWchar`) for the target, then builds wlperch with
   `-define:WLPERCH_RELEASE=true -o:speed`, linked by `clang -fuse-ld=lld`
   against the sysroot and stripped (`-s`).
4. Checks the binary (below), packages it, and writes `SHA256SUMS`.

A cold run takes about 3 minutes and downloads about 195 MB (Odin 68 MB,
qemu-user-static 60 MB, two Packages indexes 17 MB, 96 `.deb`s, 6 MB of git);
a warm one about 2 minutes, without network. Most of that
is Odin's `-o:speed` compile, about 55 s per arch.

`--publish` builds with `--version-check`, then runs `gh release create v<VERSION>`
with both tarballs and `SHA256SUMS`, as a pre-release while VERSION < 1.0. The
notes come from `--notes FILE`, else from `docs/releases/v<VERSION>.md` as
committed at HEAD, else from `$EDITOR` (not with `--yes`). Push the tag first:
`gh` is called with `--verify-tag`. Nothing is published without `--publish`.

## What is pinned, and how it is verified

| Input | Pin | Verified by |
| --- | --- | --- |
| Odin compiler | official GitHub release tarball `dev-2026-10` (= commit `84bc3fc`) for the build machine's arch | SHA256 in `pins.env`; `odin version` must print `dev-2026-10-nightly:84bc3fc` |
| odin-imgui | commit `a116eb1` (same as `build.sh`) | git commit id (git checks every object's hash) |
| Dear ImGui | `v1.92.8-docking` = commit `b61e563`, the version odin-imgui's `build.py` asks for | git commit id; the script checks that `build.py` still names that tag |
| Debian 12 packages | snapshot.debian.org at `20261020T000000Z` (Debian 12.15) | `Release` by SHA256 in `pins.env` → `main/binary-<arch>/Packages.xz` by the SHA256 in `Release` → each `.deb` by the SHA256 in `Packages` |
| qemu-user-static | from the same snapshot, only if no `qemu-aarch64(-static)` is installed | as the other `.deb`s |

The `Release` file's GPG signature is checked too when `gpgv` is installed: with
`/usr/share/keyrings/debian-archive-keyring.gpg` if the machine has it (Debian,
Ubuntu), else with `debian-archive-keyring` from the snapshot itself. The latter
proves only that the pinned `Release` is consistent with Debian's keys at that
date; the pinned hash is what the build trusts.

The sysroot is unpacked without root (`dpkg-deb --fsys-tarfile`, or `ar` +
`tar`), merged like Debian's usrmerge (`lib`, `lib64`, `bin`, `sbin` are
symlinks into `usr/`), and its absolute symlinks are made relative so nothing
points into the build machine's `/lib`.

Not pinned: the build machine's clang/lld. clang is the linker driver and
compiles stb and ImGui; its version string ends up in the binary's `.comment`
section. Another clang version gives a working binary that is not
bit-identical; the script warns when clang's major version differs from
`CLANG_MAJOR` in `pins.env`. v0.2.0 was built with Fedora's clang 22.1.8.

## What every build checks

Per binary, else the build fails:

- `file`: the right ELF arch, PIE, **stripped**, no `.symtab` or debug sections;
- **glibc floor**: needs no symbol version newer than `GLIBC_MAX` (2.34), and
  **no `GLIBCXX`** versions (from `readelf -V` / `--dyn-syms`, which is what
  `objdump -T` shows);
- `NEEDED` libraries are all in `ALLOWED_NEEDED` (`pins.env`);
- `wlperch --version` prints exactly `wlperch <VERSION>` (no "dev build"): run
  with the sysroot's own loader and libraries (under qemu for the foreign arch),
  and also directly when the machine has the runtime libraries;
- **privacy**: `strings` finds no `/home/`, `/mnt/`, `/Users/`, `/root/`, no
  user name or `$HOME`, no repository path, no e-mail address (`@openssh.com`
  key-type names excepted). Odin embeds absolute source paths for panic
  messages; they all point into the neutral build root.

The tarballs are built with `--sort=name --mtime=@<commit time> --owner=0
--group=0 --numeric-owner`, normalised modes and `gzip -n`, so they are
reproducible too (given the same gzip).

## Reproducibility

Two runs give the same binaries and tarballs, byte for byte. The binary depends
on:

- the pins (everything above);
- the host clang/lld version (see above);
- **the build root path**, because Odin embeds the absolute paths of the source
  files (and the ImGui `.cpp`s their `__FILE__`s). Keep the default
  `--build-root`, or the bytes differ (the binary is still fine).

Nothing else leaks in: there is no timestamp in the binary, and the GNU build
ID is a hash of the contents.

v0.2.0 was built by hand before this script existed, from the same pins, with
Odin in `/tmp/odin-<arch>` and the source in `/tmp/wlperch-rel-<arch>`. With
those two paths (e.g. bind-mounted from a `--keep-build` tree in an
`unshare -Urm` namespace) the rebuild of the `v0.2.0` tag is bit-identical to
the published binaries. With the default build root the binaries differ only in
those path strings (4 KiB larger).

## Bumping pins

Edit `pins.env`, run the script, and commit the new pins with the release.

- **Odin**: pick a release at <https://github.com/odin-lang/Odin/releases>; set
  `ODIN_TAG`, `ODIN_COMMIT` (`gh api repos/odin-lang/Odin/git/ref/tags/<tag>`),
  `ODIN_VERSION_STRING` (what its `odin version` prints), the file names, and
  their SHA256s (`gh release view <tag> -R odin-lang/Odin --json assets` lists
  them as `digest`; or download and `sha256sum`).
- **odin-imgui**: set `ODIN_IMGUI_COMMIT` (and `IMGUI_COMMIT` in `build.sh`). If
  its `build.py` asks for another `imgui_version`, set `IMGUI_TAG` and
  `IMGUI_COMMIT` (`git ls-remote https://github.com/ocornut/imgui.git <tag>`).
- **Debian snapshot**: pick a timestamp from
  <https://snapshot.debian.org/archive/debian/> and check its `Release` before
  trusting it:

  ```sh
  ts=20261020T000000Z; d=$(mktemp -d)
  curl -fsSL -o $d/Release     https://snapshot.debian.org/archive/debian/$ts/dists/bookworm/Release
  curl -fsSL -o $d/Release.gpg https://snapshot.debian.org/archive/debian/$ts/dists/bookworm/Release.gpg
  gpgv --keyring /usr/share/keyrings/debian-archive-keyring.gpg $d/Release.gpg $d/Release
  sha256sum $d/Release   # -> DEBIAN_RELEASE_SHA256
  ```

  Without a system keyring, use the one from the current pins:
  `release.sh --arch amd64 --keep-build` leaves it in
  `/tmp/wlperch-release-build/keyring/usr/share/keyrings/`.
- **Requirements**: `GLIBC_MAX`, `ALLOWED_NEEDED` and `CLANG_MAJOR` are checks,
  not inputs; change them only on purpose. If the app's release flags change in
  `build.sh`, change the `odin build` line in `release.sh` to match.

## CI

[`.github/workflows/release.yml`](../../.github/workflows/release.yml) runs the
script on every `v*` tag push in a Fedora 44 container and publishes the
release (`--publish --yes`), so a release is:

1. bump `VERSION` in `src/main.odin` and write `docs/releases/v<VERSION>.md`;
2. commit, `git tag -a v<VERSION>`, and push the commit and the tag.

If the release already exists (published from a local `--publish`), the
workflow only rebuilds and fails unless the published `SHA256SUMS` match its
own, a check that the release is reproducible. The tarballs are also kept as
a workflow artifact. Pushing a workflow file needs a token with the
`workflow` scope.
