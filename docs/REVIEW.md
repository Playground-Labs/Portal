# Implementation review

Baseline: `3f809e753305751b854040323ace9a1b05921f41` (the approved empty commit).
Initial implementation: `8283003`. Two independent review agents examined standards and the accepted specification. Findings were fixed before the final build.

## Standards

No documented standards violations or abstraction-related changes were requested. Four correctness findings:

1. Final framebuffer updates could be dropped while the UI was busy. Replaced dropped frames with a bounded latest-frame slot; a real two-update server test holds the UI busy and verifies the final green frame.
2. Automatic reconnect stopped after its first failed connection attempt. Retry intent now survives transient failures; a real server goes offline longer than the initial retry interval and then reconnects successfully.
3. A session strongly retained its native window, forming a cycle through the hosting view. The session’s window reference is weak.
4. Aggregate modifier flags could leave one of two physical modifier keys pressed remotely. Input now tracks left/right device masks and sends a complete Caps Lock toggle.

The standards reviewer rechecked these fixes and reported no remaining material findings in them.

## Spec

The spec review independently found final-frame loss, incomplete retry continuation, and modifier-state problems above. It also found repeated Quick Connect sessions opened duplicate windows. Connections now match normalized destination identity, SSH destination, and any explicitly supplied username; an omitted username can match the already authenticated session.

Follow-up checks found that cancellation could leave a disconnected spinner. Cancel now closes the session window. A separately reported C error-logging lifetime issue was fixed by scoping the thread-local owner to every public library call, preventing pointers from surviving dispatch-thread changes.

No deployment or public distribution was performed. Real macOS, Linux, Windows, SSH, and TLS server interoperability remains an explicit verification limit. Automated tests use actual local TCP protocol peers, not production servers.

Standards: 4 findings resolved, highest priority final-frame loss. Spec: 6 distinct findings resolved including follow-up cancellation and logging, highest priority final-frame loss/reconnect recovery.

## Authentication compatibility update

Reviewed against `a386f01` on October 1, 2026, with independent standards/security and specification reviews.

### Standards

One finding resolved: direct SASL connections incorrectly prompted as unencrypted before SASL negotiated its protection. The callback no longer makes this premature decision. SASL still requires an encrypted security layer unless TLS or an established SSH tunnel already protects it. Tests reject unprotected PLAIN and accept PLAIN over TLS and the tunnel boundary. Follow-up review found no remaining actionable security issue.

### Spec

One finding resolved: RSA input tests initially checked only local write success. They now close the connection, await the independent peer, and assert successful authentication and the decoded key event. Follow-up review found no remaining issue in the reviewed scope.

Validation: all 22 tests pass; release app builds and passes signature verification. A separate VNC-password run with `OPENSSL_MODULES` pointed at the bundled provider passes; the provider carries its own loader-relative dependency path. The real WayVNC endpoint now negotiates RSA-AES and reaches its host-key trust prompt. A fully authenticated desktop on that host remains user verification, pending their trust decision and credentials. No server settings were changed and no deployment occurred.

Standards: 1 finding resolved (incorrect SASL warning). Spec: 1 finding resolved (missing independent input assertion).

## App-wide design sweep — October 1, 2026

Replaced remaining in-app native dropdowns, switches, disclosure controls, alerts, credential prompts, rename prompts, and About panel with Portal's shared controls. Fields use the Quick Connect surface; popover choices and actions use Inter, amber selection, and rounded hover surfaces. Session submenus expand inline. OS-owned window controls, menu bar, file chooser, and Keychain permission dialogs remain native.

Standards review found missing dropdown accessibility values; spec review also found missing switch hover feedback and initial SSH password focus. All three were corrected in the shared controls. Authentication decisions, fingerprint validation, Keychain writes, and cancellation checks retain their existing behavior.

Validation: release app built successfully; existing 22 tests passed. Inspected editor and settings in dark mode, settings in light mode, dropdown selection and collapse, session controls and fullscreen enter/exit, and real-host credential presentation without entering credentials. Username receives initial focus; Tab moves to password; closing the dialog cancels the connection. SSH reuses this same focused credential component; an end-to-end SSH login was not exercised.

## WayVNC disconnect after authentication — October 1, 2026

Reproduced the saved real-host connection: RSA-AES authentication completed and the server advertised a 3440 × 1440 desktop, but the encrypted read then reported a timeout. A fragmented-record regression test reproduced the same unexpected-close error in 0.54 seconds. The cause was LibVNCClient's exact-read loop calling a buffer-aware wait while its buffer held only part of the requested data; that wait returned immediately and exhausted the retry counter.

Exact reads now wait for socket readiness, while normal message polling retains its buffered-data shortcut. The native dependency revision forces the fix into packaged builds. The regression test passes and verifies pixels plus subsequent input. Standards and spec reviews found no issues. The rebuilt app successfully rendered the real WayVNC desktop using its existing saved credentials; no credential values were inspected or logged. Temporary protocol-length diagnostics were removed.

Validation: all 23 tests pass; release build succeeds. The real-host session remained connected after the full test run.

## Connected session controls and cursor — October 1, 2026

Session controls now open inside the window rather than in a separate popover that could leave the visible session area. Opening controls releases remote keyboard capture; switching panels preserves focus and Escape dismissal. Panels scroll when their contents exceed available window height.

The local cursor uses a transparent cursor rect only over the captured, connected remote image. Portal controls, letterboxing, released input, view-only mode, and disconnected sessions retain the local cursor. This keeps the server-rendered cursor visible without a duplicate local pointer. Capture release is idempotent.

Validation: release build passes; all three SessionTests pass, including a regression check for capture release on disconnect/view-only. On the real connected WayVNC desktop, verified remote capture, visible three-dot controls afterward, switching to Sound, and Escape dismissal. Standards/spec review findings resolved and the application remains connected.

## Session toolbar missed clicks — October 1, 2026

Reproduced with a physical coordinate click inside the menu's 32 × 32 frame but outside its icon: no action, while a center click opened the menu. The shared toolbar icon label now explicitly gives the entire frame a rectangular hit area; the hover styling and rounded appearance are unchanged. This applies to Display, Sound, and Session controls.

Validation: release build succeeds. On the connected host, the formerly missed upper corner and opposite lower corner each opened the menu on the first click; clicking the upper corner again closed it. No protocol or input-capture changes were needed.

## Fullscreen notch — October 1, 2026

Fullscreen controls now overlay the desktop as a dark, bottom-rounded notch, revealed by a narrow top-center hover zone. Moving away hides it after a short delay; open menus keep it visible. Menus are centered beneath the notch. Windowed controls remain unchanged, and the obsolete fullscreen opt-out was removed from Settings. Preference observers remain active even while the toolbar is hidden.

Validation: release build passes; spec review found no issues. In the connected app, verified hidden fullscreen controls, repeated top-center reveal, menu interaction below the notch, dismissal and delayed hiding, no reveal at the top-left edge, and restoration of windowed controls on fullscreen exit. Revealing controls does not change the remote viewport dimensions.

## Fullscreen local cursor — October 1, 2026

The fullscreen notch releases keyboard capture, but the canvas tied its transparent cursor to that capture flag. Pointer movement still reaches the remote host after keyboard release. Cursor selection now follows the connected, interactive remote image independently of keyboard capture, and cursor-update/movement events reapply it after AppKit resets. View-only and disconnected canvases retain the local arrow.

Validation: a regression test first failed when updating the cursor after keyboard release, then passed with the fix; all four SessionTests pass. Release build succeeds. The rebuilt app was opened and the saved host reconnected. Live UI testing stopped after the user reported disruptive gray-screen appearances; no claim is made that this cursor change resolves that separate rendering symptom.

## Rename dialog ignores clicks — October 1, 2026

Reproduced physical Save clicks being ignored while its accessibility action worked. PortalAction synchronously started a modal dialog before SwiftUI finished dismissing the source popover. Actions now run on the next main-queue turn, allowing menu dismissal to complete before a modal event loop begins. This shared boundary covers sibling menu actions as well.

Validation: release build passes. In a separate app instance, the same physical Save click that failed before the change closed the dialog immediately; a physical Cancel click also closed it. The existing nickname was preserved. The user's original running app and connection were not restarted. Regression procedure: open saved-computer actions → Rename, then physically click Save or Cancel, including their padded corners; each must close on the first click.
