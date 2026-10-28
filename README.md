# Burrow

A little room for good work. Burrow is a native Mac app that finds stale Rust build output across your repositories and agent worktrees, with a whimsical woodland companion and explicit protection for shared compilation caches.

This is the first local development build. No remote repository or public release has been created.

## Run

Requires Apple Silicon, macOS 26+, and the currently validated Xcode 27 / Swift 6.4 toolchain.

```sh
bash scripts/build-app.sh
open dist/Burrow.app
```

Choose **Add folder**, scan your development folders, and inspect the reasons attached to each build directory. Eligible output can be reviewed and permanently removed. Initial scans and folder additions never delete anything.

```sh
bash scripts/test.sh
open dist/Burrow.app --args --demo
```

Demo mode uses clearly labeled example data and disables scanning and cleanup. It does not access the real inventory database.

## What works

- Folder selection, recursive standard Cargo-output discovery, project search and filtering, pins, Finder reveal, and protection explanations.
- Process/open-file observations, actual Cargo lock probing, Git worktree-lock and tracked-file checks, recent-write protection, redirected-output review, and refusal of symlinks and unsupported layouts.
- Shared sccache and Cargo-home exclusions; no selective pruning of compiler cache internals.
- SQLite preferences, observation history, bounded cleanup history, and pre-deletion journaling.
- Explicit reviewed deletion, fresh activity/content/identity checks, descriptor-relative traversal, and cross-process exclusion between Burrow operations.
- Opt-in scheduled cleanup per folder, configurable inactivity and schedule intervals, pause, persistent due-time tracking, and five-minute observation ticks. Closing the window leaves the menu-bar app running; quitting stops scheduling. Login startup uses SMAppService and requires a normal installed app context.
- Native SwiftUI interface with original vector artwork that changes with disk pressure. Pressure changes the illustration, not deletion authority.

## Protection limits

Protection is observation-based and best effort. Another build may start after inspection. File presence alone does not indicate a held lock. Unknown observations and incomplete inspection block cleanup. Shared caches are protected based on known/default configuration; project-specific or hidden environment overrides may need review.

The first adapter supports standard, private `target/debug` and `target/release` layouts in Git worktrees. Output overrides, cross-target layouts, symlinks, unexpected top-level content, and unknown ownership remain protected. Source files, branches, and whole worktrees are outside the deletion scope.

Permanent removal has no undo. Shared caches can reduce rebuilding work, but cannot restore every output without rebuilding. Reported artifact bytes are allocated-size estimates; APFS clones, snapshots, and concurrent activity can make actual free-space changes differ.

Automatic cleanup requires the inactivity window (24 hours by default) and continuous successful observations no more than ten minutes apart. A missed observation, restart gap, activity, or changed output resets that window. Newly discovered directories are available for reviewed cleanup only. Scheduled cleanup is off by default, requires explicit permanent-deletion acknowledgement, and needs per-folder permission.

## Architecture and remaining hardening

The shared core owns scan, policy, SQLite state, plans, and execution. The app's Engine actor is the initial worker; the CLI uses that same implementation, with a filesystem operation lease preventing concurrent Burrow writes. There is no duplicated deletion implementation.

The proposed separate authenticated XPC worker is not implemented yet. Before public release, validate permissions across macOS 26/27, production signing and login-item behavior, broader Cargo versions and lock compatibility, scanner performance, crash recovery, and update/uninstall lifecycle. The local app is ad-hoc signed, not Developer ID signed or notarized. Runtime adapter evidence supports a conservative subset of the final design.

## CLI

The bundled `burrow-worker` is a developer interface using the same inventory and protections:

```sh
dist/Burrow.app/Contents/MacOS/burrow-worker scan
dist/Burrow.app/Contents/MacOS/burrow-worker history
dist/Burrow.app/Contents/MacOS/burrow-worker clean /absolute/project/target --yes
```

The `scan [folder ...]` form replaces configured scan roots with manual-only roots. It does not delete output. Prefer folder management in the app during normal use.

## Planning

- [Product brief](docs/product-brief.md)
- [Architecture](docs/architecture.md)
- [Decision records](docs/decisions/README.md)
- [Implementation plan](docs/implementation-plan.md)
- [Local validation and remaining limits](docs/validation.md)

The docs describe accepted goals. This README distinguishes implemented behavior from remaining release work.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The complete local feature set is open source, works offline, and requires no account.
