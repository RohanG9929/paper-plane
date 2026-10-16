#!/usr/bin/env bash
# Renders every state of the remote window, light and dark, to docs/design/ for review.
# Uses SwiftUI's ImageRenderer inside the tests: no window and no Screen Recording permission.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/design
PAPERPLANE_SNAPSHOT_DIR="$PWD/docs/design" scripts/test-core.sh --filter RemoteSnapshotTests
echo "Rendered $(ls docs/design/remote-*.png | wc -l | tr -d ' ') images into docs/design/"
