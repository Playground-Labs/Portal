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

## Input latency and local remote-cursor rendering — October 1, 2026

Idle RFB polling previously held the same serial queue used by keyboard and pointer writes for up to 20 ms per read. Polling now checks readiness without waiting; the session schedules its next idle check after 5 ms without occupying the queue. Active messages drain without that delay. A fragmented or large in-progress RFB message still serializes input; this change does not claim to remove network latency or decoding time.

Portal now advertises cursor-shape support when a cursor callback is installed. It converts the server's pixels and transparency mask into a local NSCursor with the supplied hotspot, so movement does not wait for framebuffer updates. Servers without cursor-shape support retain their framebuffer cursor fallback. Empty cursor shapes clear the local shape, including a pinned LibVNCClient fix to deliver those notifications. Reconnection clears the prior shape; Portal controls retain their normal pointer.

Validation: the idle-read regression failed before the fix (50 reads took 1.196 seconds) and passed afterward (the entire test including setup took 0.023 seconds). A local wire peer verifies cursor encoding negotiation, color, transparency, hotspot, and an empty-shape update. All 27 tests pass; the final six session tests and release build also pass. No restart or real-host interaction was performed. These are local measurements, not an end-to-end benchmark of the user's connection.

## Frame scheduling and display work — October 1, 2026

The next incremental framebuffer request now goes out immediately after the current update header, before its pixels are received or decoded. The old end-of-update request was removed, keeping one next request per update. A local peer withholds pixel data while checking for that next request: the test failed before the patch and passes afterward. This pipelines ordinary RFB updates; it does not require the continuous-updates extension.

DesktopCanvas now submits the current CGImage directly to a Core Animation layer. Layer geometry handles fit/actual-size viewing and normalized contents cropping handles monitor selection. This removes repeated CGImage cropping, NSImage creation, and CPU image scaling from the draw path. Same-size frame delivery updates the layer through a dedicated publisher rather than invalidating the entire SwiftUI session interface. Size changes still notify the interface. Immutable full-frame snapshots remain to keep decoding and presentation independent and prevent tearing.

Validation: all 29 tests pass, including scheduling, fragmented encrypted frames, latest-frame delivery, reconnect, and rendering. Offscreen rendering checks verify orientation, monitor cropping, letterboxing, actual-size margins, clearing stale content, and avoiding surrounding-control updates for same-size frames. The release build succeeds. The reusable `swift -O scripts/benchmark-rendering.swift` benchmark measured approximately 2.5 ms/frame for the old 3440 × 1440 crop/scale/draw path and 0.01 ms/frame for layer submission. These measure CPU work only; layer submission excludes GPU execution/uploads and is not an end-to-end speedup claim. The active user session was not restarted or accessed.

## Cursor-only updates during window crossings — October 1, 2026

The user reports the largest lag when moving between Omarchy windows. A local wire test exposed a related Portal inefficiency: cursor-only framebuffer messages triggered a full desktop snapshot and presentation even though no screen pixels changed. Portal now marks framebuffer damage through LibVNCClient's rectangle callback and only delivers a frame when pixels or framebuffer allocation changed. Cursor callbacks remain independent. Cursor-only messages also no longer skew the automatic-quality timing samples.

Validation: the new cursor-only regression failed before the change and passes afterward, asserting that a cursor-hide message changes the cursor without replacing the desktop image. All 30 tests pass, including actual pixel updates, resize, cursor shape/hide, frame scheduling, and reconnect. Release build passes. The real Omarchy symptom has not been profiled or conclusively attributed to this issue; the user's active session was not touched.

## Enter repetition during stalled frame reads — October 1, 2026

A local wire peer reproduced a delayed release: after Enter-down it sent an incomplete framebuffer message and waited up to 500 ms for Enter-up. Portal's shared worker could not send the release until the frame completed. This can allow a remote key-repeat timer to treat a short tap as a held key; it is not proof that the user's observed repeats have this exact cause. No arbitrary debounce or suppression of repeated user key presses was added.

Input events now enter a locked pending-input queue and are drained on the existing VNC worker, including during socket-read waits. Read waits are subdivided into 5 ms intervals while preserving the existing overall retry accounting. Only key/pointer writes use this path; lifecycle changes and connection reconfiguration remain ordinary worker tasks. Generation checks reject stale input, capture-release events share the same input path, and nested native logging scopes restore the enclosing scope. All protocol access remains on one worker to avoid concurrent TLS/RSA state access. CPU-only decoding and blocked socket writes can still delay input.

Validation: the delayed-release test failed before the fix and passes afterward. Two Enter taps produce exactly two wire press/release pairs. An independent RSA-AES peer requires both Enter events before finishing an encrypted framebuffer record and verifies their order and authentication. All 33 tests pass; release build passes. No active user session was restarted or accessed.


## Continuous screen updates — October 1, 2026

The live 15-second sample captured 3,081 of 11,654 main-thread samples in Core Animation image preparation, including color conversion, and substantial VNC-worker time waiting for encrypted framebuffer bytes. These are observed costs, not proof of the entire window-crossing delay. An offscreen conversion probe did not show improvement from simply tagging frames sRGB (about 8.7 ms versus 8.0 ms for Device RGB at 3440×1440). No color-profile change was shipped; assigning the display profile to unrelated remote pixels would risk incorrect colors.

Portal now advertises and enables the RFB continuous-updates extension only after the server announces support. This removes the next-request dependency after cursor-only messages on compatible servers. Incremental requests are suppressed while streaming, the subscription region follows framebuffer resizing, and a server ending streaming resumes ordinary requests. Unsupported servers keep the existing pipelined request behavior. The pixel format remains unchanged.

Validation: `swift test --filter SessionTests/testContinuousUpdatesDeliverPixelsAfterCursorAndFollowResizeAndFallback` failed before implementation and passed afterward. Its local wire peer sends cursor and pixel updates without another framebuffer request, validates the resized subscription region, rejects incremental polling while streaming, and checks fallback after streaming ends. All 34 tests and the release build pass. No restart or real-host comparison of this change has occurred, so improvement to the user's Omarchy latency remains unverified. Sources: [RFB extension specification](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#continuousupdates-pseudo-encoding), [NeatVNC request and cursor handling](https://github.com/any1/neatvnc/blob/master/src/server.c).
