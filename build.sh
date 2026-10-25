#!/usr/bin/env bash
# Build wlperch.
#   ./build.sh            release build  -> build/wlperch
#   ./build.sh debug      debug build
#   ./build.sh run [...]  build (debug) and run with args
#   ./build.sh test       run unit tests
#   ./build.sh install    release build, copied to ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD

IMGUI_REPO=https://gitlab.com/L-4/odin-imgui.git
IMGUI_COMMIT=a116eb1ceaa6acde60219efdd56bf6c2e1aedf4c
IMGUI_DIR=third_party/odin-imgui

mkdir -p build third_party

# ---- Dear ImGui (odin-imgui bindings + static lib with FreeType) ----------
if [[ ! -d $IMGUI_DIR/.git ]]; then
	git clone "$IMGUI_REPO" "$IMGUI_DIR"
	git -C "$IMGUI_DIR" -c advice.detachedHead=false checkout "$IMGUI_COMMIT"
fi
if [[ ! -f $IMGUI_DIR/temp/imgui.cpp ]]; then
	# Generates the Odin bindings and gathers the C++ sources into temp/.
	sed -i 's/^wanted_backends = \[.*/wanted_backends = ["opengl3"]/; /^\t\t\t\t   "dx11", "dx12"/d' "$IMGUI_DIR/build.py"
	(cd "$IMGUI_DIR" && python3 build.py)
fi
IMGUI_STAMP=$IMGUI_DIR/.freetype-wchar32-build
if [[ ! -f $IMGUI_STAMP ]]; then
	echo ">> compiling imgui with FreeType"
	T=$IMGUI_DIR/temp
	cp "$IMGUI_DIR/imgui/misc/freetype/imgui_freetype.cpp" "$IMGUI_DIR/imgui/misc/freetype/imgui_freetype.h" "$T/"
	rm -f "$T"/*.o
	srcs=(imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp imgui_demo.cpp imgui_freetype.cpp
	      dcimgui_nodefaultargfunctions.cpp dcimgui_nodefaultargfunctions_internal.cpp imgui_impl_opengl3.cpp)
	pids=()
	for s in "${srcs[@]}"; do
		clang++ -c -O2 -fPIC -fno-exceptions -fno-rtti -fno-threadsafe-statics -std=c++17 \
			-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS '-DIMGUI_IMPL_API=extern "C"' -DIMGUI_ENABLE_FREETYPE -DIMGUI_USE_WCHAR32 \
			$(pkg-config --cflags freetype2) -I"$T" -I"$IMGUI_DIR/imgui" "$T/$s" -o "$T/${s%.cpp}.o" &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p"; done
	rm -f "$IMGUI_DIR/imgui_linux_x64.a"
	ar rcs "$IMGUI_DIR/imgui_linux_x64.a" "$T"/*.o
	touch "$IMGUI_STAMP"
fi
# Fedora & co ship libstdc++, not libc++.
sed -i 's/"system:c++"/"system:stdc++"/' "$IMGUI_DIR/imgui.odin"
# Icons live above U+FFFF, so ImWchar must be 32-bit (matches -DIMGUI_USE_WCHAR32).
sed -i 's/^Wchar   :: Wchar16$/Wchar   :: Wchar32/' "$IMGUI_DIR/imgui.odin"

# ---- Wayland bindings -----------------------------------------------------
P=/usr/share/wayland-protocols
WLR=/usr/share/wlr-protocols/unstable
PROTOCOLS=(
	/usr/share/wayland/wayland.xml
	$P/stable/xdg-shell/xdg-shell.xml
	$P/stable/viewporter/viewporter.xml
	$P/staging/cursor-shape/cursor-shape-v1.xml
	$P/staging/fractional-scale/fractional-scale-v1.xml
	$P/staging/single-pixel-buffer/single-pixel-buffer-v1.xml
	$P/staging/ext-idle-notify/ext-idle-notify-v1.xml
	$P/staging/ext-session-lock/ext-session-lock-v1.xml
	$P/staging/ext-image-capture-source/ext-image-capture-source-v1.xml # lock: blurred screenshot
	$P/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml
	$P/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml
	$P/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml # setup window: client-side corners
	$WLR/wlr-layer-shell-unstable-v1.xml
	$WLR/wlr-screencopy-unstable-v1.xml # lock: screenshot fallback
	$WLR/wlr-virtual-pointer-unstable-v1.xml # only used by tools/vptr (UI tests)
)
odin build tools/wlscan -out:build/wlscan -o:speed
./build/wlscan src/wl wl "${PROTOCOLS[@]}"

# ---- App ------------------------------------------------------------------
MODE=${1:-release}
LINK="$(pkg-config --libs freetype2)"
FLAGS=(-collection:third_party=third_party -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=262144)
case $MODE in
	debug|run) FLAGS+=(-debug -o:none) ;;
	test)
		# Single-threaded: several tests swap out global state (tracker, panels).
		odin test src -out:build/wlperch-test "${FLAGS[@]}" -extra-linker-flags:"$LINK" -debug -define:ODIN_TEST_THREADS=1
		exit $?
		;;
	# -s: no symbol table or debug info in the release binary (~0.35 MB);
	# panics still print source locations. ./build.sh debug keeps them.
	*)         FLAGS+=(-o:speed); LINK+=" -s" ;;
esac
odin build src -out:build/wlperch "${FLAGS[@]}" -extra-linker-flags:"$LINK"
odin build tools/vptr -out:build/vptr -o:speed
echo ">> built build/wlperch"

if [[ $MODE == install ]]; then
	mkdir -p "$HOME/.local/bin"
	# Replace atomically: a running daemon keeps its (now unlinked) binary.
	install -m 755 build/wlperch "$HOME/.local/bin/.wlperch.new"
	mv -f "$HOME/.local/bin/.wlperch.new" "$HOME/.local/bin/wlperch"
	ln -sfn wlperch "$HOME/.local/bin/wlperch-bar" # sway's swaybar_command takes one program name
	ln -sfn wlperch "$HOME/.local/bin/wlperch-askpass" # SSH_ASKPASS too
	echo ">> installed ~/.local/bin/wlperch (restart a running daemon with: wlperch restart)"
	# The sway side lives in one file; install it unless some config already has it.
	SWAYD="${XDG_CONFIG_HOME:-$HOME/.config}/sway/config.d"
	if [[ -d $SWAYD ]] && ! grep -qs "exec wlperch daemon" "$SWAYD"/*; then
		cp contrib/sway/wlperch.conf "$SWAYD/wlperch.conf"
		echo ">> installed $SWAYD/wlperch.conf (reload sway to activate)"
	fi
	# Waybar: module definitions + styling in two files next to your config.
	# Your own config/style are never edited; we print what to add.
	WAYBARD="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"
	if [[ -d $WAYBARD ]]; then
		for f in wlperch.jsonc wlperch.css; do
			if [[ ! -e $WAYBARD/$f ]]; then
				cp "contrib/waybar/$f" "$WAYBARD/$f"
				echo ">> installed $WAYBARD/$f"
			fi
		done
		if ! grep -qs 'wlperch.jsonc' "$WAYBARD"/config*; then
			cat <<'MSG'
>> waybar: to show the wlperch buttons, add to your waybar config
       "include": ["wlperch.jsonc"],
   put "custom/wlperch" (and optionally "custom/timer", "custom/sensors",
   "memory") in "modules-right", and add at the top of style.css
       @import "wlperch.css";
   then reload waybar (pkill -SIGUSR2 waybar).
MSG
		fi
	fi
fi

if [[ $MODE == run ]]; then
	shift
	exec ./build/wlperch "$@"
fi
