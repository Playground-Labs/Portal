# Portal

<img src="assets/branding/portal-round-tube-ring-thinner-alt.png" alt="Portal orange ring logo" width="160" height="160">

A native macOS VNC client with a quiet interface, soft amber controls, and one window per computer. Free software under GPL-2.0-or-later.

## Build and run

Requires macOS 14 or newer, Xcode with Swift 6, Homebrew, Python 3, and CMake. The current bundled build requires macOS 26 and has been tested on Apple silicon. The packager sets the minimum OS to the highest requirement among its actual libraries. Building for older macOS versions requires dependencies built for those systems.

```sh
brew install cmake openssl jpeg-turbo nettle
./scripts/build-app.sh
open dist/Portal.app
```

The build downloads a checksum-pinned LibVNCClient revision, applies the reviewed compatibility hooks in `scripts/patch-vnc.py`, and bundles its dynamic dependencies into `dist/Portal.app`. The app is locally ad-hoc signed. Public distribution requires a developer signature, notarization, and a release with corresponding source and dependency notices; no public release has been published.

## Connect

Enable a VNC server on your remote computer, then enter its hostname or IP address in Quick Connect. Use `host:5901` for a custom port or `[2001:db8::1]:5900` for IPv6. `vnc://` links are accepted. Portal does not install a server, open firewall ports, or provide an internet relay.

Save computers for return visits. Credentials are requested only when the server needs them, with optional macOS Keychain storage. Advanced settings include username, SSH password/key/agent authentication, image quality, display sizing, clipboard sharing, and view-only mode. SSH host keys are verified by OpenSSH; compare the displayed fingerprint before trusting a new host. A changed SSH key is rejected.

Click the remote screen to send keyboard shortcuts to it. **Control + Option + Escape** releases the keyboard. Session controls offer special keys, monitor selection, audio, fullscreen, connection details, and disconnect. Closing a session window disconnects it. Clipboard sending requires a focused, captured session; view-only disables local input and outbound clipboard.

## Compatibility

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
