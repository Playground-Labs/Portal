# Portal

<img src="assets/branding/portal-round-tube-ring-thinner-alt.png" alt="Portal orange ring logo" width="160" height="160">

A native macOS VNC client with a quiet interface, soft amber controls, and one window per computer. Free software under GPL-2.0-or-later.

## Build and run

Requires macOS 14 or newer, Xcode with Swift 6, Homebrew, Python 3, and CMake. OpenSSL, Nettle, libjpeg-turbo, and LZO are built from checksum-pinned source targeting macOS 14, so the bundled app runs on macOS 14 or newer; it has been tested on Apple silicon. The packager sets the minimum OS to the highest requirement among its actual libraries.

```sh
brew install cmake
./scripts/build-app.sh
open dist/Portal.app
```

The build downloads a checksum-pinned LibVNCClient revision, applies the reviewed compatibility hooks in `scripts/patch-vnc.py`, and bundles its dynamic dependencies into `dist/Portal.app`. The app is locally ad-hoc signed. Public distribution requires a developer signature, notarization, and a release with corresponding source and dependency notices; no public release has been published.

## Signing and notarization

Local builds are ad-hoc signed. For a local Developer ID build, install the certificate in Keychain, store notary credentials once, then build and notarize:

```sh
xcrun notarytool store-credentials portal-notary
PORTAL_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  PORTAL_SPARKLE_PUBLIC_KEY="<public key>" ./scripts/build-app.sh
./scripts/notarize-app.sh portal-notary
```

`notarize-app.sh` requires an Accepted result, staples, checks Gatekeeper, and writes `dist/Portal-macOS.zip` plus its SHA-256. If interrupted, inspect `dist/notarization-result.json` before resubmitting.

## Releases and updates

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml` on `macos-26` (Xcode 26, Swift 6 tools). It builds with `PORTAL_VERSION=X.Y.Z` and `PORTAL_BUILD=<workflow run number>`, signs, notarizes, signs the zip for Sparkle, and publishes a release on this repository containing the zip, its SHA-256, and `appcast.xml` (the previous release's appcast plus the new entry). The app reads its feed from `https://github.com/Playground-Labs/Portal/releases/latest/download/appcast.xml`. The workflow uses the built-in `GITHUB_TOKEN`; no personal access token is needed.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

One-time setup: run `./scripts/setup-release-secrets.sh` (needs `gh auth login` with admin access to the repository). It sets these Actions secrets and variables, piping values to `gh` so they never appear in arguments or output. Re-running is safe; pass `sparkle`, `notary`, or `developer-id` to redo one step.

1. **Sparkle keys.** Generates (or reuses) the EdDSA key in your login Keychain with Sparkle 2.10.0's `generate_keys`, sets the secret `SPARKLE_PRIVATE_KEY` and the variable `SPARKLE_PUBLIC_KEY`. Losing this key means existing installs can no longer verify updates, so keep the Keychain item backed up.
2. **App Store Connect API key** (Users and Access → Integrations → Team Keys, Developer role). Prompts for the `.p8` path, key ID, and issuer ID; sets `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`.
3. **Developer ID certificate.** Exports only the *Developer ID Application* identity from your login Keychain (macOS asks for permission) into a `.p12` with a random password; sets `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`. The workflow takes the signing identity from the certificate.

Build numbers come from the workflow run number and must keep increasing, because Sparkle compares them. Renaming or recreating the workflow resets the run number. Re-running a failed run keeps its build number. The release, zip, and appcast are published in one step; if that step fails after creating the release, delete the release before re-running. Each tag must be newer than the latest release. Push one tag at a time and wait for its run, since GitHub cancels queued runs beyond one. Don't delete published releases: later appcasts still list them.

**GPL requirement:** Portal is GPL-2.0-or-later. Its source is public in this repository, and each release is built from its tagged source.

## Connect

Enable a VNC server on your remote computer, then enter its hostname or IP address in Quick Connect. Use `host:5901` for a custom port or `[2001:db8::1]:5900` for IPv6. `vnc://` links are accepted. Portal does not install a server, open firewall ports, or provide an internet relay.

Save computers for return visits. Credentials are requested only when the server needs them, with optional macOS Keychain storage. Advanced settings include username, SSH password/key/agent authentication, image quality, display sizing, clipboard sharing, and view-only mode. SSH host keys are verified by OpenSSH; compare the displayed fingerprint before trusting a new host. A changed SSH key is rejected.

Click the remote screen to send keyboard shortcuts to it. **Control + Option + Escape** releases the keyboard. To send macOS system shortcuts such as Command–Space and Command–Tab, allow Portal in **System Settings → Privacy & Security → Accessibility**, then click the remote screen again. Capture ends when the session loses focus, disconnects, or enters view-only mode. Without permission, ordinary keys still work, but macOS keeps its system shortcuts. Session controls offer special keys, monitor selection, audio, fullscreen, connection details, and disconnect. Closing a session window disconnects it. Clipboard sending requires a focused, captured session; view-only disables local input and outbound clipboard.

## Compatibility

For Wayland hosts where the pointer slows during window-focus changes, **Display → Use local cursor** draws an arrow on your Mac independently of screen updates. Disable the server's cursor overlay first (for WayVNC, remove `--render-cursor`) to avoid duplicate pointers. This optional mode uses a fixed arrow, rather than remote cursor shapes, and is saved per computer. It is off by default.

- Automatically negotiates RSA-AES (RA2 / RA2-256 and authentication-only variants), TLS/VeNCrypt, SASL, VNC password, Apple ARD, UltraVNC MSLogonII, or no authentication. Full-session encryption is preferred when offered. RSA-AES supports WayVNC without changing its server configuration. New or changed RSA keys require an explicit trust decision; trusted keys are remembered separately from TLS certificates.
- Protocol tests cover RSA-AES, TLS username/password, SASL PLAIN over TLS, Apple ARD, UltraVNC MSLogonII, legacy RFB 3.3 password authentication, and ordinary RFB 3.8 connections. This is not a claim of compatibility with every server version, SASL mechanism, or proprietary cloud service. RealVNC cloud/account connections and Apple High Performance Screen Sharing are outside standard VNC support.
- Remote resizing uses ExtendedDesktopSize when a server advertises a single display. Otherwise Portal scales the desktop to fit. Multi-monitor layouts are preserved; individual monitor selection is available when the server reports their geometry. Actual-size mode provides scrolling.
- Remote audio uses the **QEMU Audio extension** (16-bit stereo, 44.1 kHz). Ordinary VNC servers often provide no audio. Portal explicitly shows audio unavailable until a compatible server announces support. It does not implement Apple High Performance Screen Sharing audio.
- Clipboard text supports extended UTF-8 clipboard where available and the legacy VNC text format otherwise. No file transfer or microphone forwarding.
- Direct unencrypted sessions require consent, remembered per saved endpoint. TLS certificate trust, RSA server-key trust, and SSH host-key trust are separate. Portal cannot detect whether your route uses a VPN.
- Nearby discovery depends on `_rfb._tcp` advertisements and macOS local-network permission.

## Development and checks

```sh
./scripts/prepare-tests.sh
swift build
swift test
```

Tests cover address parsing, saved settings with no passwords in JSON, corrupt-file protection, and real TCP RFB exchanges: VNC password authentication, pixels, keyboard/pointer input, clipboard, monitor layouts, safe resize requests, PCM audio, final-frame delivery under UI load, and reconnect after a server outage. RSA tests use a separate PyCryptodome implementation (installed in `.build/auth-python` by `prepare-tests.sh`) and verify rejection of tampered records and untrusted keys. The test peers are not production VNC servers.

To verify the app bundle’s legacy-password provider after building it:

```sh
OPENSSL_MODULES="$PWD/dist/Portal.app/Contents/Frameworks" swift test --filter VNCTests/testPasswordAuthenticationAndSingleDisplayResize
```

Settings live in `~/Library/Application Support/Portal/computers.json`; SSH fingerprints in the adjacent `known_hosts`. Passwords live in Keychain. Appearance and app preferences use macOS UserDefaults. Portal has no telemetry.

See [the accepted product brief](docs/SPEC.md) and [dependency notices](THIRD_PARTY.md).
