#!/bin/zsh
# Render one board to PNG: tools/shot.sh <boardId> <height> [scale]
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --force-device-scale-factor=${3:-1} \
  --window-size=1976,$2 --virtual-time-budget=3000 --screenshot="export/orbit-$1.png" "file://$PWD/index.html?board=$1" >/dev/null 2>&1
echo "export/orbit-$1.png"
