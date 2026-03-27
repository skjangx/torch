#!/bin/bash
# Launch Content Shell (raw Chromium) to demo native browser rendering.
# This is the same rendering engine Atlas/OWL uses.
# Try: right-click, scroll, type in forms, open DevTools (Cmd+Alt+I)

CONTENT_SHELL="$HOME/chromium/src/out/Release/Content Shell.app"

if [ ! -d "$CONTENT_SHELL" ]; then
    echo "Content Shell not built. Run from ~/chromium/src:"
    echo "  autoninja -C out/Release content_shell"
    exit 1
fi

URL="${1:-https://www.google.com}"
echo "Opening Content Shell with: $URL"
echo ""
echo "This is RAW Chromium (not CEF). All input is native:"
echo "  - Right-click: context menu works"
echo "  - Scroll: native smooth scrolling"
echo "  - Type: native IME support"
echo "  - Cmd+Alt+I: DevTools"
echo "  - All form controls, dropdowns, etc. work natively"
echo ""

open "$CONTENT_SHELL" --args --no-sandbox "$URL"
