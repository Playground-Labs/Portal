#!/usr/bin/env bash
# Sets the GitHub Actions secrets and variables used by .github/workflows/release.yml.
# Run it yourself: secret values are piped to `gh` on stdin and never printed or passed as arguments.
#
# Usage: scripts/setup-release-secrets.sh [sparkle] [notary] [developer-id]   (default: all three)
# Env:   PORTAL_REPO=owner/name (default: the current gh repository)
set -euo pipefail

SPARKLE_URL=https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
root="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(sparkle notary developer-id)
for step in "${steps[@]}"; do
  case "$step" in sparkle|notary|developer-id) ;; *) die "unknown step '$step' (use sparkle, notary, developer-id)";; esac
done

command -v gh > /dev/null || die 'GitHub CLI not found: brew install gh'
gh auth status > /dev/null 2>&1 || die 'not logged in to GitHub: run gh auth login'
repo="${PORTAL_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
[ "$(gh api "repos/$repo" --jq .permissions.admin)" = true ] || die "you need admin access to $repo to set Actions secrets"
echo "Repository: $repo"

umask 077
tmp="$(mktemp -d)"
cleanup() {
  [ -z "${verify_keychain:-}" ] || security delete-keychain "$verify_keychain" 2> /dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# Value comes from stdin. Names are logged to a file because these often run in a pipeline subshell.
set_secret() { gh secret set "$1" --repo "$repo" > /dev/null; echo "secret $1" >> "$tmp/set-names"; }
set_variable() { gh variable set "$1" --repo "$repo" > /dev/null; echo "variable $1" >> "$tmp/set-names"; }

setup_sparkle() {
  echo '== Sparkle update-signing key'
  # ponytail: SPARKLE_BIN lets tests substitute generate_keys; normally the pinned release is downloaded.
  local bin="${SPARKLE_BIN:-}"
  if [ -z "$bin" ]; then
    curl -fsSL -o "$tmp/sparkle.tar.xz" "$SPARKLE_URL"
    echo "$SPARKLE_SHA256  $tmp/sparkle.tar.xz" | shasum -a 256 -c - > /dev/null || die 'Sparkle download checksum mismatch'
    mkdir "$tmp/sparkle"
    tar -xJf "$tmp/sparkle.tar.xz" -C "$tmp/sparkle"
    bin="$tmp/sparkle/bin"
  fi
  # Creates the key in the login Keychain, or reports the existing one.
  "$bin/generate_keys" > /dev/null
  local public
  public="$("$bin/generate_keys" -p)"
  [ -n "$public" ] || die 'generate_keys -p printed no public key'
  "$bin/generate_keys" -x "$tmp/sparkle.key" > /dev/null
  [ -s "$tmp/sparkle.key" ] || die 'generate_keys -x exported nothing'
  tr -d '\n' < "$tmp/sparkle.key" | set_secret SPARKLE_PRIVATE_KEY
  rm -f "$tmp/sparkle.key"
  printf '%s' "$public" | set_variable SPARKLE_PUBLIC_KEY
  echo "Public key: $public"
  cat << 'EOF'
BACK UP THIS KEY. It lives in your login Keychain ("Private key for signing Sparkle updates").
If it is lost, installed copies of Portal can never verify another update.
Export a backup with: generate_keys -x <file>, and store that file somewhere safe and offline.
EOF
}

setup_notary() {
  echo '== App Store Connect API key (notarization)'
  local p8 key_id issuer_id
  read -r -p 'Path to AuthKey_XXXX.p8: ' p8
  p8="${p8/#\~/$HOME}"
  [ -f "$p8" ] || die "no such file: $p8"
  grep -q 'BEGIN PRIVATE KEY' "$p8" || die "$p8 is not a .p8 private key"
  read -r -p 'Key ID: ' key_id
  read -r -p 'Issuer ID: ' issuer_id
  [[ "$key_id" =~ ^[A-Z0-9]{10}$ ]] || die 'Key ID should be 10 letters/digits'
  [[ "$issuer_id" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'Issuer ID should be a UUID'
  base64 -i "$p8" | tr -d '\n' | set_secret NOTARY_KEY_P8_BASE64
  printf '%s' "$key_id" | set_secret NOTARY_KEY_ID
  printf '%s' "$issuer_id" | set_secret NOTARY_ISSUER_ID
}

find_openssl() {
  local brew_ssl
  brew_ssl="$(brew --prefix openssl@3 2> /dev/null)/bin/openssl"
  if [ -x "$brew_ssl" ]; then
    openssl="$brew_ssl"
  elif [ -x "$root/.build/native/bin/openssl" ]; then
    openssl="$root/.build/native/bin/openssl"
    export OPENSSL_MODULES="$root/.build/native/lib/ossl-modules"
  else
    return 1
  fi
}

# Writes $tmp/devid.p12 (password in $tmp/p12.pw) holding only the identity with SHA-1 $1,
# taken from the PKCS#12 file $2 whose password is in file $3. Prints nothing secret.
filter_identity() {
  local sha="$1" src="$2" src_pw="$3" cert="" key="" pub f fp issuer
  rm -f "$tmp"/cert[0-9]*.pem "$tmp"/key[0-9]*.pem "$tmp"/ca[0-9]*.pem
  "$openssl" pkcs12 -legacy -in "$src" -passin "file:$src_pw" -nokeys -out "$tmp/certs.pem" || return 1
  "$openssl" pkcs12 -legacy -in "$src" -passin "file:$src_pw" -nocerts -noenc -out "$tmp/keys.pem" 2> /dev/null || return 1
  awk -v d="$tmp" '/-----BEGIN CERTIFICATE-----/{n++} n{print > (d "/cert" n ".pem")}' "$tmp/certs.pem"
  awk -v d="$tmp" '/-----BEGIN PRIVATE KEY-----/{n++} n{print > (d "/key" n ".pem")}' "$tmp/keys.pem"
  rm -f "$tmp/keys.pem"
  for f in "$tmp"/cert[0-9]*.pem; do
    [ -f "$f" ] || continue
    fp="$("$openssl" x509 -in "$f" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
    [ "$fp" = "$sha" ] && cert="$f"
  done
  [ -n "$cert" ] || { echo 'The selected Developer ID certificate is not in the .p12.' >&2; return 1; }
  pub="$("$openssl" x509 -in "$cert" -noout -pubkey)"
  for f in "$tmp"/key[0-9]*.pem; do
    [ -f "$f" ] || continue
    [ "$("$openssl" pkey -in "$f" -pubout 2> /dev/null)" = "$pub" ] && key="$f"
  done
  [ -n "$key" ] || { echo 'The private key for the Developer ID certificate is not in the .p12.' >&2; return 1; }
  # Add the issuing Apple intermediate when the Keychain has it.
  issuer="$("$openssl" x509 -in "$cert" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')"
  : > "$tmp/chain.pem"
  security find-certificate -a -c 'Developer ID Certification Authority' -p > "$tmp/cas.pem" 2> /dev/null || true
  awk -v d="$tmp" '/-----BEGIN CERTIFICATE-----/{n++} n{print > (d "/ca" n ".pem")}' "$tmp/cas.pem"
  for f in "$tmp"/ca[0-9]*.pem; do
    [ -f "$f" ] || continue
    if [ "$("$openssl" x509 -in "$f" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')" = "$issuer" ]; then
      cat "$f" > "$tmp/chain.pem"
      break
    fi
  done
  local chain_args=()
  [ -s "$tmp/chain.pem" ] && chain_args=(-certfile "$tmp/chain.pem")
  # -legacy (3DES, SHA-1 MAC) is what every macOS `security import` accepts.
  # Built twice: the uploaded copy under the secret password, a twin under a throwaway one for verify_p12.
  "$openssl" rand -hex 16 > "$tmp/verify.pw"
  for f in p12 verify; do
    "$openssl" pkcs12 -export -legacy -in "$cert" -inkey "$key" ${chain_args[@]+"${chain_args[@]}"} -name 'Developer ID Application' \
      -passout "file:$tmp/$f.pw" -out "$tmp/devid-$f.p12" || return 1
  done
  mv "$tmp/devid-p12.p12" "$tmp/devid.p12"
  rm -f "$tmp"/key[0-9]*.pem
}

# Proves the twin p12 imports into a fresh keychain as exactly one identity, with SHA-1 $1.
verify_p12() {
  local sha="$1" kc_pw ids search
  kc_pw="$("$openssl" rand -hex 16)"
  verify_keychain="$tmp/verify.keychain-db"
  search="$(security list-keychains -d user | tr -d '"')"
  security delete-keychain "$verify_keychain" 2>/dev/null || true
  security create-keychain -p "$kc_pw" "$verify_keychain"
  # create-keychain may add itself to the search list; put the user's list back.
  # shellcheck disable=SC2086
  security list-keychains -d user -s $search
  security unlock-keychain -p "$kc_pw" "$verify_keychain"
  # The throwaway password is not a secret, so passing it as an argument is fine.
  security import "$tmp/devid-verify.p12" -k "$verify_keychain" -f pkcs12 -P "$(cat "$tmp/verify.pw")" > /dev/null || return 1
  ids="$(security find-identity -p codesigning "$verify_keychain" | grep -E '^ +[0-9]+\)' | sort -u -k2,2)"
  security delete-keychain "$verify_keychain"
  verify_keychain=""
  [ "$(printf '%s\n' "$ids" | grep -c .)" = 1 ] && printf '%s' "$ids" | grep -q "$sha"
}

setup_developer_id() {
  echo '== Developer ID Application certificate'
  local keychain="${DEVELOPER_ID_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}" ids sha
  ids="$(security find-identity -v -p codesigning "$keychain" | grep '"Developer ID Application: ' | sort -u -k2,2 || true)"
  case "$(printf '%s' "$ids" | grep -c .)" in
    0) die 'no valid Developer ID Application identity in your Keychain' ;;
    1) sha="$(printf '%s' "$ids" | awk '{print $2}')" ;;
    *) printf '%s\n' "$ids"; read -r -p 'SHA-1 of the identity to use: ' sha ;;
  esac
  sha="$(printf '%s' "$sha" | tr '[:lower:]' '[:upper:]')"
  [[ "$sha" =~ ^[0-9A-F]{40}$ ]] || die 'enter the 40-character SHA-1 shown above'
  printf '%s\n' "$ids" | grep -q " $sha " || die "no Developer ID identity with SHA-1 $sha"
  echo "Using: $(printf '%s\n' "$ids" | grep " $sha " | sed 's/^[^"]*//')"
  find_openssl || die 'OpenSSL 3 is needed to repackage the identity: brew install openssl@3'
  "$openssl" rand -base64 24 | tr -d '\n' > "$tmp/p12.pw"
  # Ephemeral password protecting only the temporary all-identities export.
  "$openssl" rand -hex 24 > "$tmp/all.pw"
  echo 'macOS will ask to allow exporting keys from your Keychain: click Allow (once per identity).'
  if ! { security export -k "$keychain" -t identities -f pkcs12 -P "$(cat "$tmp/all.pw")" -o "$tmp/all.p12" > /dev/null &&
    filter_identity "$sha" "$tmp/all.p12" "$tmp/all.pw" && verify_p12 "$sha"; }; then
    rm -f "$tmp/all.p12"
    cat << 'EOF'
Could not isolate the Developer ID identity automatically.
Export it by hand instead: Keychain Access > My Certificates > right-click
"Developer ID Application: ..." > Export > .p12.
EOF
    local manual manual_pw
    read -r -p 'Path to the exported .p12: ' manual
    manual="${manual/#\~/$HOME}"
    [ -f "$manual" ] || die "no such file: $manual"
    read -r -s -p 'Its password: ' manual_pw
    echo
    printf '%s' "$manual_pw" > "$tmp/manual.pw"
    manual_pw=""
    { filter_identity "$sha" "$manual" "$tmp/manual.pw" && verify_p12 "$sha"; } ||
      die 'that .p12 does not contain the selected Developer ID identity in a form macOS imports'
  fi
  rm -f "$tmp/all.p12"
  base64 -i "$tmp/devid.p12" | tr -d '\n' | set_secret DEVELOPER_ID_P12_BASE64
  set_secret DEVELOPER_ID_P12_PASSWORD < "$tmp/p12.pw"
}

for step in "${steps[@]}"; do
  case "$step" in
    sparkle) setup_sparkle ;;
    notary) setup_notary ;;
    developer-id) setup_developer_id ;;
  esac
done

echo "== Set on $repo:"
sed 's/^/  /' "$tmp/set-names"
