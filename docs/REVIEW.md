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

Validation: all 22 tests pass; release app builds and passes signature verification. The real WayVNC endpoint now negotiates RSA-AES and reaches its host-key trust prompt. A fully authenticated desktop on that host remains user verification, pending their trust decision and credentials. No server settings were changed and no deployment occurred.

Standards: 1 finding resolved (incorrect SASL warning). Spec: 1 finding resolved (missing independent input assertion).
