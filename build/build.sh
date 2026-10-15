#!/bin/sh
# Builds play-test packages: build/dist/kusogaki-together-<version>-{windows,macos,linux}.*
# Run from anywhere: sh build/build.sh   (needs curl, 7z, python3; LÖVE is downloaded)
# KUSOGAKI_SERVER=<address> presets the lobby's server (default: our VPS).
set -eu
cd "$(dirname "$0")/.."
LOVE=11.5
SERVER=${KUSOGAKI_SERVER:-103.150.92.215}
NAME="Kusogaki Together"
VERSION=$(sed -n 's/.*GAME = "\(.*\)".*/\1/p' core/version.lua)
BASE=kusogaki-together-$VERSION
CACHE=build/cache STAGE=build/stage DIST=build/dist

for tool in curl 7z python3; do
    command -v $tool >/dev/null || { echo "missing: $tool"; exit 1; }
done
rm -rf "$STAGE" && mkdir -p "$CACHE" "$STAGE" "$DIST"

fetch() { # file in the LÖVE release (or a full URL) -> cached path
    url=$1
    case $url in http*) ;; *) url=https://github.com/love2d/love/releases/download/$LOVE/$1 ;; esac
    out=$CACHE/$(basename "$url")
    if [ ! -f "$out" ]; then
        curl -fsSL --retry 3 -o "$out.part" "$url" >&2 && mv -f "$out.part" "$out" \
            || { echo "download failed: $url" >&2; exit 1; }
    fi
    echo "$out"
}

# ── The game (.love): tracked files only, no server, tests, docs or sources ──
git ls-files -z | python3 -c '
import sys, os, shutil
skip = ("server/", "tests/", "build/", "assets/deprecated/")
for path in sys.stdin.read().split("\0"):
    if not path or path.startswith(skip) or path.endswith((".md", ".aseprite")) or path.startswith("."):
        continue
    if not os.path.exists(path):
        continue  # deleted in the working tree
    dest = os.path.join(sys.argv[1], path)
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    shutil.copy2(path, dest)
' "$STAGE/game"
# Players start at the menu (guards against shipping a development shortcut).
grep -q 'sceneEngine.start("menu")' "$STAGE/game/main.lua" || { echo "main.lua does not start at the menu"; exit 1; }
# The lobby's server, preset (a player's own online.txt in the save folder wins).
printf 'server=%s\nrelayOnly=0\n' "$SERVER" > "$STAGE/game/online.txt"
(cd "$STAGE/game" && 7z a -tzip -mx=9 -bd -bso0 ../game.love .)
GAME=$STAGE/game.love

# ── Windows: love.exe with the game appended ─────────────────────────────────
7z x -bd -bso0 -o"$STAGE/win" "$(fetch love-$LOVE-win64.zip)"
win=$(find "$STAGE/win" -maxdepth 1 -mindepth 1 -type d | head -n 1)
cat "$win/love.exe" "$GAME" > "$win/$NAME.exe"
rm -f "$win/love.exe" "$win/lovec.exe" "$win/readme.txt" "$win/changes.txt"
rm -rf "$STAGE/$BASE-windows" && mv "$win" "$STAGE/$BASE-windows"
rm -f "$DIST/$BASE-windows.zip"
(cd "$STAGE" && 7z a -tzip -mx=9 -bd -bso0 "../dist/$BASE-windows.zip" "$BASE-windows")

# ── macOS: love.app with the game inside, renamed (unsigned) ─────────────────
7z x -bd -bso0 -snld -o"$STAGE/mac" "$(fetch love-$LOVE-macos.zip)"
app="$STAGE/mac/$NAME.app"
mv "$STAGE/mac/love.app" "$app"
cp "$GAME" "$app/Contents/Resources/game.love"
python3 - "$app/Contents/Info.plist" "$NAME" <<'EOF'
import plistlib, sys
path, name = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    plist = plistlib.load(f)
plist["CFBundleIdentifier"] = "com.kusogaki.together"
plist["CFBundleName"] = name
plist.pop("UTExportedTypeDeclarations", None)  # do not claim .love files
plist.pop("CFBundleDocumentTypes", None)
with open(path, "wb") as f:
    plistlib.dump(plist, f)
EOF
rm -f "$DIST/$BASE-macos.zip"
(cd "$STAGE/mac" && 7z a -tzip -mx=9 -bd -bso0 -snl "../../dist/$BASE-macos.zip" "$NAME.app")

# ── Linux: the LÖVE AppImage with the game appended to its binary ────────────
image=$(fetch love-$LOVE-x86_64.AppImage)
tool=$(fetch https://github.com/AppImage/appimagetool/releases/download/1.9.0/appimagetool-x86_64.AppImage)
chmod +x "$image" "$tool"
(cd "$STAGE" && APPIMAGE_EXTRACT_AND_RUN=1 "../../$image" --appimage-extract >/dev/null)
root=$STAGE/squashfs-root
cat "$root/bin/love" "$GAME" > "$root/bin/love.fused" && mv "$root/bin/love.fused" "$root/bin/love"
chmod +x "$root/bin/love"
sed -i "s/^Name=.*/Name=$NAME/" "$root"/*.desktop
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$tool" --no-appstream "$root" "$DIST/$BASE-linux-x86_64.AppImage" >/dev/null 2>&1 \
    || { echo "appimagetool failed"; exit 1; }

cp build/PLAYTEST.txt "$DIST/"
rm -rf "$STAGE"
ls -lh "$DIST"
