# Local development validation

Date: October 28, 2026.

## Environment

Apple Silicon Mac running macOS 26.6.2. Xcode's macOS SDK is 27.0 and Swift is 6.4. The development package deploys to macOS 26.0 and uses Swift 5 language mode. Cross-version macOS 27 runtime validation is still pending.

## Verified behavior

The native application builds and is packaged as an ad-hoc-signed local app. The window was inspected through native accessibility and a screenshot. The woodland scene, project inventory, search filtering, and selected protection explanations rendered correctly using clearly labeled demo data. Demo cleanup controls are disabled.

The core suite contains 19 tests using generated temporary Git/Cargo fixtures. It covers reviewed deletion while source and a shared-cache sentinel survive; active and incomplete process inspection; pins; held versus leftover Cargo lock files; tracked output; symbolic links; Cargo output overrides; unexpected content; changed output and settings after review; new observations; observation gaps; overlapping roots; cross-process operation exclusion; scheduled cleanup through the normal executor; a locked linked worktree; and observation of a real child process's working directory.

Destructive tests operate only on disposable fixtures. No real development worktree output was removed during this implementation.

## Implementation boundaries

The Engine actor is the app's initial worker. The CLI uses the same core and SQLite database; a filesystem operation lease excludes concurrent Burrow operations. The separate authenticated XPC service remains future work. Closing the window leaves the app/menu-bar worker running; quitting stops it.

Scheduled eligibility and deletion are covered with an injected clock and real fixture filesystem operations. Production login-item approval, long-running sleep/wake behavior, the full macOS support matrix, automatic notification delivery, and notarized updates have not been validated. Inspection issues are shown in-app; the prototype does not yet send system notifications.

The adapter intentionally preserves unsupported Cargo layouts and redirected output. Broader Cargo-version compatibility and genuine concurrent Cargo build behavior require further validation. A synthetic flock test is evidence of lock handling, not proof that every Cargo release uses the same protocol.

Estimated allocated bytes are shown. Explicit before/after free-space attribution per cleanup is not yet implemented. Observation-based protection cannot eliminate an unrelated process starting after inspection.
