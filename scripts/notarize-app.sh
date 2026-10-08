#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then
  echo 'Usage: ./scripts/notarize-app.sh KEYCHAIN_PROFILE' >&2
  exit 2
fi
app=dist/Portal.app
codesign --verify --deep --strict "$app"
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
if ! [[ "$signature" == *"Authority=Developer ID Application:"* && "$signature" == *"runtime"* && "$signature" == *"Timestamp="* ]]; then
  echo 'Build with PORTAL_SIGNING_IDENTITY set to a Developer ID Application certificate first.' >&2
  exit 1
fi
ditto -c -k --keepParent "$app" dist/Portal-notarization.zip
xcrun notarytool submit dist/Portal-notarization.zip --keychain-profile "$1" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait --output-format json > dist/notarization-result.json
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path('dist/notarization-result.json').read_text())
print('Notarization:', result.get('status'), 'Submission:', result.get('id'))
if result.get('status') != 'Accepted':
    raise SystemExit('Not accepted. Inspect the submission with xcrun notarytool log using its ID and your Keychain profile.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --keepParent "$app" dist/Portal-macOS.zip
(cd dist && shasum -a 256 Portal-macOS.zip > Portal-macOS.zip.sha256)
