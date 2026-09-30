# Portal

Native macOS VNC client, free and open source. The remote computer already has a reachable VNC server. No accounts, remote companion, file transfer, or microphone forwarding.

## Accepted design

[Paper design](https://app.paper.design/file/01KZC7Y4BDGPCKK3CQ7CE96TMH/p-I-0), artboards 01–10. Button direction **B** is selected: 30-point height, 5-point corners, soft amber primary and neutral secondary fills, no button shadows or borders. System typography, balanced list density, light/dark/system appearance. Settings has no ellipsis.

Home contains Quick Connect, saved computers, and separately discovered Bonjour computers. Basic setup asks for name and address, with Advanced disclosure. Credentials are requested only when the server needs them and optionally saved in macOS Keychain.

One native window per active computer. Compact title bar: centered computer name, display/sound/session icons, no persistent bottom status bar. Toolbar hides in fullscreen when configured. Keyboard shortcuts go to the remote computer while captured, with Control–Option–Escape to release and special-key actions in the session menu.

## Required behavior

- Connections to common macOS Screen Sharing, Linux, and Windows VNC servers, locally, through VPN, or to reachable internet addresses.
- Optional SSH tunnel with password or private-key authentication and host identity checking.
- Warn before unencrypted direct connections; remember acceptance per saved connection. Reset warnings in Settings. Never silently bypass certificate or changed-host checks.
- Text clipboard sharing with per-connection control, view-only mode, fullscreen, fit/actual-size viewing, automatic/manual image quality, and automatic reconnect with cancel/retry.
- Automatic remote resize when the server supports it; local fit fallback. Show all monitors by default, allow selection when the server exposes layout.
- Remote sound for compatible audio-capable servers. First supported extension: QEMU Audio. Clearly indicate unsupported audio; no claim of universal VNC audio or Apple High Performance compatibility.
- Persist computer preferences and recent use locally. Never write passwords into connection JSON or logs.
- Useful authentication, connection failure, reconnect, and first-use states.

## Agreed verification boundaries

Address parsing; saving/loading computers without passwords; real local RFB integration for authentication, framebuffer, input, clipboard, resizing and QEMU audio. Test these public boundaries, not private implementation structure.

Review baseline: initial empty commit `3f809e753305751b854040323ace9a1b05921f41`. Commit implementation to the existing main branch. No deployment is authorized.
