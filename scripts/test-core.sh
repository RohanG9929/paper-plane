#!/usr/bin/env bash
# Runs the PaperPlaneCore tests. Works with full Xcode, and with only the Command Line
# Tools, which ship Swift Testing outside the compiler's default search path.
set -euo pipefail
cd "$(dirname "$0")/../core"
DEVELOPER_DIR="$(xcode-select -p)"
if [[ "$DEVELOPER_DIR" == *CommandLineTools* ]]; then
  FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
  LIBS="$DEVELOPER_DIR/Library/Developer/usr/lib"
  exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$LIBS" \
    "$@"
fi
exec swift test "$@"
