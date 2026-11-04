#!/bin/zsh
# Renders the Seek panel against the demo home and saves a PNG.
#   scripts/demo/shot.sh <name> "<query>" ["System Events command" ...]
# env: APPEARANCE=light|dark (default dark), WAIT=<seconds before showing the panel>
#
# Needs: a release build (swift build -c release), scripts/demo/make-home.sh run
# first, and Accessibility permission for your terminal (osascript sends ⌥Space).
# Quit any installed Seek first so the hotkey reaches this instance.
set -uo pipefail
cd "$(dirname "$0")/../.."
H=$PWD/demo-home
OUT=$PWD/build/shots
mkdir -p $OUT
pkill -f .build/release/Seek; sleep 0.6
rm -f $OUT/$1.png

# CFFIXED_USER_HOME makes NSHomeDirectory() (and Application Support) point at the demo home.
CFFIXED_USER_HOME=$H SEEK_APPEARANCE=${APPEARANCE:-dark} SEEK_SNAPSHOT=$OUT/$1.png \
  .build/release/Seek > $OUT/$1.log 2>&1 &
sleep ${WAIT:-4}
osascript -e 'tell application "System Events" to key code 49 using {option down}'
sleep 0.8
[[ -n "$2" ]] && osascript -e "tell application \"System Events\" to keystroke \"$2\""
sleep 1.8
NAME=$1; shift 2
for cmd in "$@"; do osascript -e "tell application \"System Events\" to $cmd"; sleep 1.2; done
sleep 1.2
pkill -f .build/release/Seek
[[ -f $OUT/$NAME.png ]] && echo "saved $OUT/$NAME.png" || echo "no snapshot for $NAME (see $OUT/$NAME.log)"
