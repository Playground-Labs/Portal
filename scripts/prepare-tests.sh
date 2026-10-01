#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-native.sh
python3 -m venv .build/auth-python
.build/auth-python/bin/python3 -m pip install --disable-pip-version-check 'pycryptodome==3.23.0'
