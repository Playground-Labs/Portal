# Portal

Native macOS VNC client, free and open source. The remote computer already has a reachable VNC server. No accounts, remote companion, file transfer, or microphone forwarding.

## Accepted design

[Paper design](https://app.paper.design/file/01KZC7Y4BDGPCKK3CQ7CE96TMH/p-I-0), artboards 01–10. Button direction **B** is selected: 30-point height, 5-point corners, soft amber primary and neutral secondary fills, no button shadows or borders. Inter interface typography with JetBrains Mono for addresses, ports, and key paths, balanced list density, light/dark/system appearance. Settings has no ellipsis. Icon actions use 18–20-point symbols in 32 × 32-point hover targets with 5-point rounded corners. Text buttons retain hover areas matching their button shape. Corner icon targets have equal 6-point vertical and outer-side insets in 44-point custom bars.

Across the whole app, use Notion, Obsidian, and Linear as references for quiet surfaces, restrained typography, compact headers, and consistent controls. Use icons alone only for familiar actions (add, settings, display, sound, more), with tooltips and accessibility labels. Keep text for consequential or ambiguous actions, including Connect, Save, Cancel, trust decisions, and recovery. Avoid decorative action icons, redundant labels, and filler copy.

Home has a native compact toolbar with no visible title and an icon-only add action. Its starting frame is 515 × 660 points; both dimensions are fixed and the home window is not resizable. Home contains Quick Connect, saved computers, and separately discovered Bonjour computers. Basic setup asks for name and address, with Advanced disclosure. Credentials are requested only when the server needs them and optionally saved in macOS Keychain.

One native window per active computer. Compact title bar: centered computer name, display/sound/session icons, no persistent bottom status bar. Toolbar hides in fullscreen when configured. Keyboard shortcuts go to the remote computer while captured, with Control–Option–Escape to release and special-key actions in the session menu.

## Required behavior

- Automatically negotiate common VNC authentication, including WayVNC RSA-AES, VNC password, TLS/VeNCrypt, SASL, Apple ARD, and UltraVNC MSLogonII; prefer full-session encryption and keep credentials and identity prompts simple.
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

### Consistent app-owned controls

All app-owned fields, toggles, dropdowns, action menus, disclosures, dialogs, and About content use Portal's shared visual language. Credential, trust, SSH, error, removal, and rename prompts use custom Portal panels. Session submenu choices expand within their panel. Retain OS-owned window controls, menu bar integration, file chooser, and Keychain permission dialogs.
