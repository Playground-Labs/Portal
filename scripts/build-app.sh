#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-native.sh
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
python3 scripts/package.py "$binary_dir/Portal"
