#!/usr/bin/env bash
# Reproducible release build of wlperch for x86_64 and aarch64 Linux.
# See tools/release/README.md, or run with --help.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
# shellcheck source=pins.env
source "$HERE/pins.env"
GITHUB_REPO=mcourteaux/wlperch

usage() {
	cat <<'EOF'
Usage: tools/release/release.sh [options]

Builds release tarballs of the committed HEAD (never the working tree) against
a pinned Debian 12 sysroot with a pinned Odin compiler, checks them, and
writes wlperch-<version>-<cpu>-linux.tar.gz plus SHA256SUMS.

Options:
  --arch amd64|arm64|all  target(s) to build (default: all)
  --out DIR               where the tarballs go (default: build/release in the repo)
  --cache DIR             download cache (default: ${XDG_CACHE_HOME:-~/.cache}/wlperch-release)
  --build-root DIR        scratch build dir (default: /tmp/wlperch-release-build). Its path
                          is embedded in the binary (Odin panic locations), so a
                          different one gives a different, still valid, binary.
  --keep-build            keep the build root afterwards (default: delete on success)
  --version-check         fail unless the tree is clean and HEAD is tagged v<VERSION>
  --allow-dirty           with --version-check: allow uncommitted changes (they are
                          not built anyway; the build uses HEAD)
  --publish               after building, create the GitHub release with gh (a
                          pre-release while VERSION < 1.0). Implies --version-check
                          and --arch all; asks for confirmation.
  --notes FILE            release notes for --publish (default: docs/releases/v<VERSION>.md
                          as committed at HEAD, else open $EDITOR)
  --yes                   do not ask for confirmation before publishing (and never
                          open an editor: the notes must exist)
  -h, --help              this help

Environment: CC (default clang), CXX (default clang++), AR (default llvm-ar or ar).
EOF
}

# ---- options ----------------------------------------------------------------
ARCH=all
OUT=$REPO/build/release
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/wlperch-release
BR=/tmp/wlperch-release-build
KEEP_BUILD=0
VERSION_CHECK=0
ALLOW_DIRTY=0
PUBLISH=0
NOTES=
YES=0
while [[ $# -gt 0 ]]; do
	case $1 in
		--arch) ARCH=${2:?--arch needs a value}; shift ;;
		--arch=*) ARCH=${1#*=} ;;
		--out) OUT=${2:?--out needs a value}; shift ;;
		--out=*) OUT=${1#*=} ;;
		--cache) CACHE=${2:?--cache needs a value}; shift ;;
		--cache=*) CACHE=${1#*=} ;;
		--build-root) BR=${2:?--build-root needs a value}; shift ;;
		--build-root=*) BR=${1#*=} ;;
		--keep-build) KEEP_BUILD=1 ;;
		--version-check) VERSION_CHECK=1 ;;
		--allow-dirty) ALLOW_DIRTY=1 ;;
		--publish) PUBLISH=1 ;;
		--notes) NOTES=${2:?--notes needs a file}; shift ;;
		--notes=*) NOTES=${1#*=} ;;
		--yes|-y) YES=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "release.sh: unknown option: $1 (see --help)" >&2; exit 2 ;;
	esac
	shift
done

if [[ -t 2 ]]; then C_B=$'\033[1m' C_Y=$'\033[33m' C_E=$'\033[31m' C_N=$'\033[0m'; else C_B= C_Y= C_E= C_N=; fi
log()  { printf '%s>> %s%s\n' "$C_B" "$*" "$C_N" >&2; }
warn() { printf '%srelease.sh: warning: %s%s\n' "$C_Y" "$*" "$C_N" >&2; }
die()  { printf '%srelease.sh: error: %s%s\n' "$C_E" "$*" "$C_N" >&2; exit 1; }

case $ARCH in
	amd64|arm64) ARCHES=("$ARCH") ;;
	all) ARCHES=(amd64 arm64) ;;
	*) die "--arch must be amd64, arm64 or all" ;;
esac
if ((PUBLISH)); then
	[[ $ARCH == all ]] || die "--publish needs --arch all"
	((ALLOW_DIRTY == 0)) || die "--publish cannot be combined with --allow-dirty"
	VERSION_CHECK=1
	[[ -z $NOTES || -f $NOTES ]] || die "notes file not found: $NOTES"
fi

# Absolute paths; the build root must be a plain, dedicated directory.
OUT=$(realpath -m "$OUT")
CACHE=$(realpath -m "$CACHE")
[[ $BR == /* ]] || BR=$PWD/$BR
case $BR in /|"$HOME"|"$HOME"/|"$REPO"|"$REPO"/*) die "refusing to use $BR as build root" ;; esac

# ---- environment --------------------------------------------------------------
export LC_ALL=C TZ=UTC
umask 022
unset ODIN_ROOT # Odin must use the pinned tree next to its binary
CC=${CC:-clang}
CXX=${CXX:-clang++}
AR=${AR:-$(command -v llvm-ar || command -v ar || true)}

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool '$1' (see tools/release/README.md)"; }
for t in git curl tar gzip sha256sum python3 file readelf strings "$CC" "$CXX" ld.lld; do need "$t"; done
[[ -n $AR ]] || die "missing tool 'llvm-ar' or 'ar'"
((PUBLISH == 0)) || need gh
if ! command -v dpkg-deb >/dev/null 2>&1; then
	need xz
fi

clang_major=$("$CC" -dumpversion | cut -d. -f1)
[[ $clang_major == "$CLANG_MAJOR" ]] ||
	warn "clang $clang_major (pins.env expects $CLANG_MAJOR): the binaries will work but won't be bit-identical to other builds"

case $(uname -m) in
	x86_64) HOST_ARCH=amd64 ;;
	aarch64|arm64) HOST_ARCH=arm64 ;;
	*) die "unsupported build machine: $(uname -m) (need x86_64 or aarch64 Linux)" ;;
esac
triple_of()  { case $1 in amd64) echo x86_64-linux-gnu ;; arm64) echo aarch64-linux-gnu ;; esac; }
cpu_of()     { case $1 in amd64) echo x86_64 ;; arm64) echo aarch64 ;; esac; }
imgui_arch() { case $1 in amd64) echo x64 ;; arm64) echo arm64 ;; esac; }

T0=$SECONDS
step() { log "$* [+$((SECONDS - T0))s]"; }

# ---- source ---------------------------------------------------------------------
COMMIT=$(git -C "$REPO" rev-parse HEAD)
VERSION=$(git -C "$REPO" show HEAD:src/main.odin | sed -n 's/^VERSION :: "\([^"]*\)".*/\1/p')
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not read VERSION :: \"x.y.z\" from src/main.odin"
SOURCE_DATE_EPOCH=$(git -C "$REPO" log -1 --format=%ct HEAD)
export SOURCE_DATE_EPOCH
TAG=v$VERSION

# The release notes: --notes, else the committed docs/releases/<tag>.md, else
# $EDITOR (after the build). Resolved now, so a missing file fails fast.
if ((PUBLISH)) && [[ -z $NOTES ]]; then
	if git -C "$REPO" cat-file -e "HEAD:docs/releases/$TAG.md" 2>/dev/null; then
		NOTES=$(mktemp "${TMPDIR:-/tmp}/wlperch-notes.XXXXXX.md")
		trap 'rm -f "$NOTES"' EXIT
		git -C "$REPO" show "HEAD:docs/releases/$TAG.md" >"$NOTES"
	elif ((YES)); then
		die "no release notes: commit docs/releases/$TAG.md or pass --notes FILE"
	fi
fi

dirty=$(git -C "$REPO" status --porcelain)
if ((VERSION_CHECK)); then
	if [[ -n $dirty ]] && ((ALLOW_DIRTY == 0)); then
		die "working tree is dirty (commit or stash, or pass --allow-dirty)"
	fi
	tags=$(git -C "$REPO" tag --points-at HEAD)
	grep -qx "$TAG" <<<"$tags" ||
		die "HEAD ($(git -C "$REPO" rev-parse --short HEAD)) is not tagged $TAG (VERSION in src/main.odin is $VERSION)"
fi
[[ -z $dirty ]] || warn "uncommitted changes are NOT part of this build (it builds HEAD $COMMIT)"
log "wlperch $VERSION from $(git -C "$REPO" rev-parse --short HEAD), arches: ${ARCHES[*]}"
log "cache: $CACHE   build root: $BR   out: $OUT"

# ---- build root -------------------------------------------------------------------
MARK=.wlperch-release-build-root
if [[ -e $BR && ! -e $BR/$MARK ]] && [[ -n $(ls -A "$BR") ]]; then
	die "$BR exists and was not made by release.sh; remove it or pick --build-root"
fi
mkdir -p "$BR" "$OUT" "$CACHE"
touch "$BR/$MARK"
if command -v flock >/dev/null 2>&1; then
	exec 9>"$BR/$MARK"
	flock -n 9 || die "another release.sh is using $BR"
fi

# ---- downloads ----------------------------------------------------------------------
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# fetch URL DEST [SHA256]: download once into the cache; verify every time.
fetch() {
	local url=$1 dest=$2 want=${3:-}
	if [[ -f $dest && -n $want ]]; then
		[[ $(sha256_of "$dest") == "$want" ]] && return 0
		warn "cached $(basename "$dest") has the wrong hash; downloading again"
		rm -f "$dest"
	fi
	if [[ ! -f $dest ]]; then
		mkdir -p "$(dirname "$dest")"
		curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 30 -o "$dest.part" "$url" ||
			{ rm -f "$dest.part"; die "download failed: $url"; }
		mv -f "$dest.part" "$dest"
	fi
	if [[ -n $want ]]; then
		local got
		got=$(sha256_of "$dest")
		if [[ $got != "$want" ]]; then
			rm -f "$dest"
			die "SHA256 mismatch for $url: got $got, want $want"
		fi
	fi
}

# git_export NAME REPO COMMIT DEST: DEST gets the files of COMMIT (no .git).
# A bare repo in the cache keeps the objects; git checks every object's hash.
git_export() {
	local name=$1 repo=$2 commit=$3 dest=$4 bare=$CACHE/git/$1.git
	if [[ ! -d $bare ]]; then
		git init -q --bare "$bare"
		git -C "$bare" config uploadpack.allowAnySHA1InWant true
	fi
	if ! git -C "$bare" cat-file -e "$commit^{commit}" 2>/dev/null; then
		log "fetching $name $commit"
		git -C "$bare" fetch -q --depth 1 "$repo" "$commit" 2>/dev/null ||
			git -C "$bare" fetch -q "$repo" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' ||
			die "could not fetch $repo"
	fi
	[[ $(git -C "$bare" rev-parse --verify -q "$commit^{commit}") == "$commit" ]] ||
		die "$name: commit $commit not found in $repo"
	rm -rf "$dest"
	mkdir -p "$dest"
	git -C "$dest" init -q
	git -C "$dest" -c core.autocrlf=false fetch -q --depth 1 "$bare" "$commit"
	git -C "$dest" -c core.autocrlf=false -c advice.detachedHead=false checkout -q FETCH_HEAD
	rm -rf "$dest/.git"
}

DEB=$CACHE/debian/$DEBIAN_SNAPSHOT
SNAP_URL=$DEBIAN_MIRROR/$DEBIAN_SNAPSHOT

# Packages.xz of an arch, checked against the pinned Release.
debian_index() {
	local arch=$1 path want
	path=main/binary-$1/Packages.xz
	want=$(awk -v p="$path" '/^SHA256:/{s=1;next} /^[^ ]/{s=0} s && $3==p {print $1}' "$DEB/Release")
	[[ -n $want ]] || die "$path not in Release"
	fetch "$SNAP_URL/dists/$DEBIAN_SUITE/$path" "$DEB/$arch/Packages.xz" "$want"
}

# debian_debs ARCH LIST PKG...: fetch + verify the .debs; LIST gets their cache paths.
debian_debs() {
	local arch=$1 list=$2 fn sha size ver
	shift 2
	python3 -I "$HERE/debian.py" select "$DEB/Release" "main/binary-$arch/Packages.xz" "$DEB/$arch/Packages.xz" "$@" >"$list.idx"
	: >"$list"
	while read -r fn sha size ver; do
		fetch "$SNAP_URL/$fn" "$CACHE/debian/pool/$(basename "$fn")" "$sha"
		echo "$CACHE/debian/pool/$(basename "$fn")" >>"$list"
	done <"$list.idx"
}
# debian_install ARCH DIR PKG...: unpack the packages into DIR.
debian_install() {
	local arch=$1 dir=$2 list deb
	shift 2
	list=$dir.debs
	debian_debs "$arch" "$list" "$@"
	while read -r deb; do deb_extract "$deb" "$dir"; done <"$list"
}

# deb_extract DEB DIR (no root needed; existing dir symlinks such as lib -> usr/lib are kept).
deb_extract() {
	if command -v dpkg-deb >/dev/null 2>&1; then
		dpkg-deb --fsys-tarfile "$1" | tar -x --keep-directory-symlink --no-same-owner -C "$2"
	else
		local member
		member=$("$AR" t "$1" | grep '^data\.tar') || die "no data.tar in $1"
		case $member in
			*.xz)  "$AR" p "$1" "$member" | xz -dc ;;
			*.zst) "$AR" p "$1" "$member" | zstd -dc ;;
			*.gz)  "$AR" p "$1" "$member" | gzip -dc ;;
			*.tar) "$AR" p "$1" "$member" ;;
			*) die "unknown member $member in $1" ;;
		esac | tar -x --keep-directory-symlink --no-same-owner -C "$2"
	fi
}

step "Debian $DEBIAN_SUITE snapshot $DEBIAN_SNAPSHOT"
fetch "$SNAP_URL/dists/$DEBIAN_SUITE/Release" "$DEB/Release" "$DEBIAN_RELEASE_SHA256"
idx_arches=("${ARCHES[@]}")
[[ " ${ARCHES[*]} " == *" $HOST_ARCH "* ]] || idx_arches+=("$HOST_ARCH")
for a in "${idx_arches[@]}"; do debian_index "$a"; done

# Signature: belt and braces, the Release hash is pinned anyway. Prefer the
# build machine's own Debian keyring; else the one in the pinned snapshot.
GPG_STATUS="skipped (no gpgv); the Release file is pinned by SHA256"
if command -v gpgv >/dev/null 2>&1; then
	fetch "$SNAP_URL/dists/$DEBIAN_SUITE/Release.gpg" "$DEB/Release.gpg"
	keyring=/usr/share/keyrings/debian-archive-keyring.gpg
	ksrc="the system keyring"
	if [[ ! -f $keyring ]]; then
		rm -rf "$BR/keyring" && mkdir -p "$BR/keyring"
		debian_install "${idx_arches[0]}" "$BR/keyring" "$DEBIAN_KEYRING_PACKAGE"
		keyring=$BR/keyring/usr/share/keyrings/debian-archive-keyring.gpg
		ksrc="$DEBIAN_KEYRING_PACKAGE from the snapshot"
	fi
	if gpgv --keyring "$keyring" "$DEB/Release.gpg" "$DEB/Release" >"$BR/gpgv.log" 2>&1; then
		GPG_STATUS="good signature ($ksrc)"
	else
		cat "$BR/gpgv.log" >&2
		die "gpgv: bad signature on $DEB/Release"
	fi
fi
log "Release: SHA256 pinned; GPG: $GPG_STATUS"

ODIN_FILE_VAR=ODIN_FILE_$HOST_ARCH ODIN_SHA_VAR=ODIN_SHA256_$HOST_ARCH
ODIN_TGZ=$CACHE/odin/${!ODIN_FILE_VAR}
step "Odin $ODIN_TAG (${!ODIN_FILE_VAR})"
fetch "$ODIN_URL_BASE/${!ODIN_FILE_VAR}" "$ODIN_TGZ" "${!ODIN_SHA_VAR}"

# ---- per-arch build -----------------------------------------------------------------
declare -A BIN_OF TGZ_OF
build_arch() {
	local A=$1 TRIPLE CPU R O S I TMPD
	TRIPLE=$(triple_of "$A")
	CPU=$(cpu_of "$A")
	R=$BR/$A/sysroot
	O=$BR/$A/odin
	S=$BR/$A/wlperch
	rm -rf "${BR:?}/$A"
	mkdir -p "$R" "$O"

	step "[$A] sysroot"
	# usrmerge, as Debian 12 itself: /lib, /bin, ... are symlinks into /usr.
	mkdir -p "$R"/usr/{bin,sbin,lib,lib64}
	for d in bin sbin lib lib64; do ln -s "usr/$d" "$R/$d"; done
	local pkgs=()
	read -r -a pkgs <<<"$(echo $DEBIAN_PACKAGES)"
	debian_install "$A" "$R" "${pkgs[@]}"
	echo "  $(wc -l <"$R.debs") packages, e.g. $(awk '$1 ~ /\/libc6_/ {print "libc6 " $4}' "$R.debs.idx")"
	python3 -I "$HERE/debian.py" fix-symlinks "$R" >/dev/null
	[[ -e $R/usr/lib/$TRIPLE/libc.so.6 ]] || die "[$A] sysroot has no libc.so.6"

	step "[$A] Odin + stb"
	tar -xzf "$ODIN_TGZ" --strip-components=1 -C "$O"
	[[ $("$O/odin" version) == *"$ODIN_VERSION_STRING"* ]] || die "unexpected odin version: $("$O/odin" version)"
	TMPD=$BR/$A/obj
	mkdir -p "$TMPD" "$O/vendor/stb/lib"
	local c
	for c in stb_image stb_image_write stb_image_resize stb_truetype stb_rect_pack stb_vorbis stb_sprintf; do
		(cd "$O/vendor/stb/src" && "$CC" --target="$TRIPLE" --sysroot="$R" -c -O2 -Os -fPIC "$c.c" -o "$TMPD/$c.o")
		rm -f "$O/vendor/stb/lib/$c.a"
		"$AR" rcs "$O/vendor/stb/lib/$c.a" "$TMPD/$c.o"
	done

	step "[$A] source + Dear ImGui"
	git clone -q --no-local "$REPO" "$S"
	git -C "$S" -c advice.detachedHead=false checkout -q --detach "$COMMIT"
	I=$S/third_party/odin-imgui
	git_export odin-imgui "$ODIN_IMGUI_REPO" "$ODIN_IMGUI_COMMIT" "$I"
	git_export imgui "$IMGUI_REPO" "$IMGUI_COMMIT" "$I/imgui"
	grep -q "^imgui_version = \"$IMGUI_TAG\"" "$I/build.py" || die "odin-imgui's build.py does not pin $IMGUI_TAG"
	# Same edits as build.sh: libstdc++ (not libc++), 32-bit ImWchar.
	sed -i 's/"system:c++"/"system:stdc++"/; s/^Wchar   :: Wchar16$/Wchar   :: Wchar32/' "$I/imgui.odin"
	grep -q '"system:stdc++"' "$I/imgui.odin" && grep -q '^Wchar   :: Wchar32$' "$I/imgui.odin" ||
		die "imgui.odin edits did not apply"
	# What odin-imgui's build.py gathers into temp/ for the opengl3 backend, plus FreeType.
	local T=$I/temp
	mkdir -p "$T"
	cp "$I"/imgui/*.h "$I"/imgui/*.cpp "$I"/dcimgui/*.h "$I"/dcimgui/*.cpp \
		"$I"/imgui/backends/imgui_impl_opengl3.{h,cpp} "$I"/imgui/backends/imgui_impl_opengl3_loader.h \
		"$I"/imgui/misc/freetype/imgui_freetype.{h,cpp} "$T/"
	local s pids=() p
	for s in imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp imgui_demo.cpp imgui_freetype.cpp \
		dcimgui_nodefaultargfunctions.cpp dcimgui_nodefaultargfunctions_internal.cpp imgui_impl_opengl3.cpp; do
		"$CXX" --target="$TRIPLE" --sysroot="$R" -c -O2 -fPIC -fno-exceptions -fno-rtti -fno-threadsafe-statics -std=c++17 \
			-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS '-DIMGUI_IMPL_API=extern "C"' -DIMGUI_ENABLE_FREETYPE -DIMGUI_USE_WCHAR32 \
			-I"$R/usr/include/freetype2" -I"$T" -I"$I/imgui" "$T/$s" -o "$T/${s%.cpp}.o" &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p"; done
	local OA
	OA=$(imgui_arch "$A")
	"$AR" rcs "$I/imgui_linux_$OA.a" "$T"/*.o
	# imgui_impl_opengl3.odin names the x64 archive on every Linux arch.
	[[ $OA == x64 ]] || cp "$I/imgui_linux_$OA.a" "$I/imgui_linux_x64.a"

	step "[$A] wlperch (odin -o:speed)"
	mkdir -p "$S/build"
	# Keep the -define flags in step with build.sh's release mode.
	(cd "$S" && "$O/odin" build src -target:"linux_$A" -out:build/wlperch -collection:third_party=third_party \
		-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=262144 -define:WLPERCH_RELEASE=true -o:speed \
		-extra-linker-flags:"--target=$TRIPLE --sysroot=$R -fuse-ld=lld -lfreetype -s")
	BIN_OF[$A]=$S/build/wlperch

	verify_arch "$A"
	package_arch "$A"
}

# ---- checks -----------------------------------------------------------------------
find_qemu() { # QEMU := a qemu-user binary able to run CPU, fetched if not installed
	local cpu=$1 q d=$BR/qemu
	for q in "qemu-$cpu-static" "qemu-$cpu"; do
		if command -v "$q" >/dev/null 2>&1; then QEMU=$(command -v "$q"); return; fi
	done
	if [[ ! -x $d/usr/bin/qemu-$cpu-static ]]; then
		mkdir -p "$d"
		debian_install "$HOST_ARCH" "$d" "$DEBIAN_QEMU_PACKAGE"
	fi
	[[ -x $d/usr/bin/qemu-$cpu-static ]] || die "no qemu-$cpu-static in $DEBIAN_QEMU_PACKAGE"
	QEMU=$d/usr/bin/qemu-$cpu-static
}

verify_arch() {
	local A=$1 B=${BIN_OF[$1]} TRIPLE R CPU f
	TRIPLE=$(triple_of "$A")
	R=$BR/$A/sysroot
	CPU=$(cpu_of "$A")
	step "[$A] checks"

	f=$(file -b "$B")
	case $A in
		amd64) [[ $f == *"ELF 64-bit LSB pie executable, x86-64"* ]] || die "[$A] file: $f" ;;
		arm64) [[ $f == *"ELF 64-bit LSB pie executable, ARM aarch64"* ]] || die "[$A] file: $f" ;;
	esac
	[[ $f == *", stripped"* ]] || die "[$A] not stripped: $f"
	local sections dynsyms
	sections=$(readelf -S -W "$B")
	! grep -qE '\.symtab|\.debug_' <<<"$sections" || die "[$A] has a symbol table or debug info"
	echo "  file:     ${f%%, BuildID*}, stripped"

	# Symbol versions the binary needs (= objdump -T's version column).
	local vers glibc_max
	vers=$(readelf -V -W "$B" | sed -n 's/.*Name: \([A-Z]*_[0-9.]*\).*/\1/p' | sort -uV)
	glibc_max=$(grep '^GLIBC_[0-9]' <<<"$vers" | sed 's/GLIBC_//' | sort -V | tail -1)
	[[ $(printf '%s\n%s\n' "$glibc_max" "$GLIBC_MAX" | sort -V | tail -1) == "$GLIBC_MAX" ]] ||
		die "[$A] needs GLIBC_$glibc_max (max allowed $GLIBC_MAX)"
	! grep -q '^GLIBCXX' <<<"$vers" || die "[$A] needs GLIBCXX symbols: $(grep '^GLIBCXX' <<<"$vers" | tr '\n' ' ')"
	dynsyms=$(readelf --dyn-syms -W "$B")
	! grep -q '@GLIBCXX' <<<"$dynsyms" || die "[$A] imports GLIBCXX symbols"
	echo "  glibc:    needs GLIBC_$glibc_max (<= $GLIBC_MAX), no GLIBCXX"

	local needed n
	needed=$(readelf -d -W "$B" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
	for n in $needed; do
		[[ " $(echo $ALLOWED_NEEDED) " == *" $n "* ]] || die "[$A] unexpected NEEDED library: $n"
	done
	echo "  NEEDED:   $(echo $needed)"

	# --version, through the sysroot's own loader and libraries (no host libs needed).
	local ld libpath out run=()
	ld=$(ls "$R"/usr/lib/"$TRIPLE"/ld-linux-*.so.* | head -1)
	libpath=$R/usr/lib/$TRIPLE:$R/usr/lib
	if [[ $A != "$HOST_ARCH" ]]; then find_qemu "$CPU"; run=("$QEMU"); fi
	out=$("${run[@]}" "$ld" --library-path "$libpath" "$B" --version 2>&1) || die "[$A] --version failed: $out"
	[[ $out == "wlperch $VERSION" ]] || die "[$A] --version printed '$out', want 'wlperch $VERSION'"
	echo "  version:  '$out'${run:+ (under $(basename "${run[0]}"))}"
	if [[ $A == "$HOST_ARCH" ]]; then
		# And as a user would run it, if this machine has the libraries.
		if out=$("$B" --version 2>&1); then
			[[ $out == "wlperch $VERSION" ]] || die "[$A] native --version printed '$out'"
			echo "  native:   '$out'"
		else
			warn "[$A] could not run natively (missing host libraries?): $out"
		fi
	fi

	# Privacy: no home dirs, user names, machine paths or e-mail addresses.
	local strs bad=() u
	strs=$(strings -a -n 4 "$B")
	grep -qE '/home/|/mnt/|/Users/|/root/' <<<"$strs" && bad+=("$(grep -oE '(/home/|/mnt/|/Users/|/root/)[^ "]{0,40}' <<<"$strs" | sort -u | head -3)")
	for u in "${USER:-}" "$(id -un)" "$HOME" "$REPO"; do
		[[ ${#u} -ge 3 && $u != root ]] || continue # root: covered by /root/
		grep -qiwF -- "$u" <<<"$strs" && bad+=("contains '$u'")
	done
	local mails
	mails=$(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' <<<"$strs" | grep -vE '@openssh\.com$' | sort -u || true)
	[[ -z $mails ]] || bad+=("e-mail-like strings: $(echo $mails)")
	((${#bad[@]} == 0)) || die "[$A] privacy check failed: ${bad[*]}"
	echo "  privacy:  ok (embedded source paths: $(grep -oE "^$BR/[^/]+/[^/]+" <<<"$strs" | sort -u | tr '\n' ' '))"
}

# ---- packaging ---------------------------------------------------------------------
package_arch() {
	local A=$1 S=$BR/$1/wlperch name stage
	name=wlperch-$VERSION-$(cpu_of "$A")-linux
	stage=$BR/$A/pkg
	step "[$A] package $name.tar.gz"
	mkdir -p "$stage/$name/licenses"
	install -m 755 "${BIN_OF[$A]}" "$stage/$name/wlperch"
	git -C "$S" archive --format=tar HEAD README.md contrib | tar -x -C "$stage/$name"
	install -m 644 "$S/third_party/odin-imgui/imgui/LICENSE.txt" "$stage/$name/licenses/LICENSE-DearImGui.txt"
	install -m 644 "$S/assets/fonts/LICENSE-Inter.txt" "$S/assets/fonts/LICENSE-JetBrainsMono.txt" \
		"$S/assets/fonts/LICENSE-NerdFontsSymbols.txt" "$stage/$name/licenses/"
	install -m 644 "$BR/$A/odin/LICENSE" "$stage/$name/licenses/LICENSE-Odin.txt"
	install -m 644 "$S/assets/emoji/LICENSE.txt" "$stage/$name/licenses/LICENSE-emoji-data.txt"
	# Reproducible: fixed order, times, owners and modes; no name/time in gzip.
	tar -C "$stage" --sort=name --format=gnu --mtime="@$SOURCE_DATE_EPOCH" \
		--owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
		-cf - "$name" | gzip -9 -n >"$OUT/$name.tar.gz.part"
	mv -f "$OUT/$name.tar.gz.part" "$OUT/$name.tar.gz"
	local owners
	owners=$(tar -tvzf "$OUT/$name.tar.gz" | awk '{print $2}' | sort -u)
	[[ $owners == 0/0 ]] || die "[$A] archive has owners other than 0/0: $owners"
	TGZ_OF[$A]=$OUT/$name.tar.gz
}

for A in "${ARCHES[@]}"; do build_arch "$A"; done

step "SHA256SUMS"
(cd "$OUT" && for A in "${ARCHES[@]}"; do sha256sum "$(basename "${TGZ_OF[$A]}")"; done >SHA256SUMS)

echo
log "done in $((SECONDS - T0))s: wlperch $VERSION ($COMMIT)"
for A in "${ARCHES[@]}"; do
	printf '  %-6s binary  %9d bytes  sha256 %s\n' "$A" "$(stat -c %s "${BIN_OF[$A]}")" "$(sha256_of "${BIN_OF[$A]}")"
done
sed 's/^/  /' "$OUT/SHA256SUMS"
echo "  toolchain: $("$CC" --version | head -1); Odin $("$BR/${ARCHES[0]}/odin/odin" version | awk '{print $3}')"
echo "  sysroot: Debian $DEBIAN_SUITE @ $DEBIAN_SNAPSHOT; Release GPG: $GPG_STATUS"
echo "  output: $OUT"

if ((KEEP_BUILD == 0)); then
	rm -rf "${BR:?}"/{amd64,arm64,qemu,keyring} "$BR"/*.debs "$BR"/*.debs.idx "$BR/gpgv.log"
	rm -f "$BR/$MARK"
	rmdir "$BR" 2>/dev/null || true
fi

# ---- publish -----------------------------------------------------------------------
if ((PUBLISH)); then
	prerelease=()
	[[ ${VERSION%%.*} -ge 1 ]] || prerelease=(--prerelease)
	notes=$NOTES
	if [[ -z $notes ]]; then
		notes=$(mktemp "${TMPDIR:-/tmp}/wlperch-notes.XXXXXX.md")
		trap 'rm -f "$notes"' EXIT
		printf '# Release notes for wlperch %s. Lines starting with # are dropped.\n' "$VERSION" >"$notes"
		"${VISUAL:-${EDITOR:-vi}}" "$notes"
		sed -i '/^#/d' "$notes"
	fi
	[[ -n $(tr -d '[:space:]' <"$notes") ]] || die "empty release notes; not publishing"
	echo
	echo "About to publish $TAG to github.com/$GITHUB_REPO ${prerelease[*]:-(full release)} with:"
	for A in "${ARCHES[@]}"; do echo "  ${TGZ_OF[$A]}"; done
	echo "  $OUT/SHA256SUMS"
	if ((YES == 0)); then
		read -r -p "Publish? [y/N] " ans
		[[ $ans == [yY]* ]] || die "not published"
	fi
	assets=()
	for A in "${ARCHES[@]}"; do assets+=("${TGZ_OF[$A]}"); done
	gh release create "$TAG" -R "$GITHUB_REPO" --verify-tag --title "wlperch $VERSION" \
		--notes-file "$notes" "${prerelease[@]}" "${assets[@]}" "$OUT/SHA256SUMS"
fi
