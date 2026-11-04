#!/bin/zsh
# Builds Seek.app, signs it with a stable identity, installs to ~/Applications, launches it.
#   ./build.sh               build, install, launch (for your own Mac)
#   ./build.sh --release     build a universal (Apple silicon + Intel) app in build/, don't install
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Seek.app
MODEL=Resources/potion-base-8M
RELEASE=false
[[ "${1:-}" == "--release" ]] && RELEASE=true

# Semantic search model (Model2Vec potion-base-8M, MIT, ~30 MB). Kept out of git.
if [[ ! -f $MODEL/model.safetensors ]]; then
  echo "Downloading $MODEL…"
  mkdir -p $MODEL
  for f in model.safetensors tokenizer.json config.json README.md; do
    curl -fL --progress-bar -o "$MODEL/$f" "https://huggingface.co/minishlab/potion-base-8M/resolve/main/$f"
  done
fi

if $RELEASE; then
  # One build per architecture, then lipo them into a universal binary.
  for A in arm64 x86_64; do
    swift build -c release --triple $A-apple-macosx14.0 --scratch-path .build/$A
  done
  BIN=build/Seek-universal
  mkdir -p build
  lipo -create -output $BIN .build/arm64/release/Seek .build/x86_64/release/Seek
else
  swift build -c release
  BIN=.build/release/Seek
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Seek"
cp Info.plist "$APP/Contents/Info.plist"
cp -R $MODEL "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"

# Stable signature so macOS remembers folder-access grants across rebuilds.
# Release builds (and machines without a developer certificate) are signed ad hoc.
IDENTITY=""
$RELEASE || IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --options runtime --entitlements Seek.entitlements --sign "${IDENTITY:--}" "$APP"

if $RELEASE; then
  echo "Built $APP"
  exit 0
fi

mkdir -p ~/Applications
pkill -x Seek 2>/dev/null || true
rm -rf ~/Applications/Seek.app
cp -R "$APP" ~/Applications/
open ~/Applications/Seek.app
echo "Installed and launched ~/Applications/Seek.app  (hotkey: ⌥Space)"
