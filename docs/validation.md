# Local development validation

Date: October 28, 2026.

## Environment

Apple Silicon Mac running macOS 26.6.2. Xcode's macOS SDK is 27.0 and Swift is 6.4. The development package deploys to macOS 26.0 and uses Swift 5 language mode. Cross-version macOS 27 runtime validation is still pending.

## Verified behavior

The core suite has 27 tests using generated temporary Git fixtures. The 19 Cargo and engine tests cover:

- reviewed deletion while source and a shared-cache sentinel survive
- active and incomplete process inspection, pins, held versus leftover Cargo lock files, and tracked output
- symbolic links, Cargo output overrides, and unexpected content
- changed output and settings after review, new observations, and observation gaps
- overlapping roots and cross-process operation exclusion
- scheduled cleanup through the normal executor
- a locked linked worktree, and observation of a real child process's working directory

The 8 Node adapter tests cover:

- removing `node_modules` containing `.bin` and workspace symbolic links while their destinations survive
- hard-linked store files excluded from reclaimable bytes
- protection when the folder is not ignored by Git, has no lockfile, or holds no installed packages
- pinning a whole worktree, process names in reasons, run grouping, free-space samples, and worktree repository and branch names

A read-only inventory of the maintainer's real folders (`~/.t3/worktrees`, 398 Git worktrees) through `headroom-cli` with a separate state directory found 137 folders and 133 GB of output in about 41 seconds. Discovery took under a second for the walk and about 6 seconds for Git manifest listing; inspection took the rest. All large folders were correctly kept: recent builds, live processes (`postgres`, `claude`, `zsh`, and a local API server), and Cargo `target` folders containing a Postgres data directory. No real development output was removed.

The packaged app was captured on every screen in light and dark appearances using demo data, and read-only against the real inventory (`--snapshot`). The sweep screens were captured only with simulated demo cleanup.

## Implementation boundaries

The Engine actor is the app's initial worker. The CLI uses the same core and SQLite database (schema version 2: run grouping and free-space samples). A filesystem operation lease excludes concurrent Headroom operations. The separate authenticated XPC service remains future work. Closing the window leaves the menu bar app running; quitting stops it.

Scheduled eligibility and deletion are covered with an injected clock and real fixture filesystem operations. Production login-item approval, long-running sleep/wake behavior, the full macOS support matrix, notification delivery, and notarized updates have not been validated.

Each scan re-measures every candidate folder (about 2.6 million files in the inventory above). With automatic cleanup on, this repeats every five minutes at utility priority so observations stay continuous. Discovery results are cached between scans. Event-driven change detection would reduce this cost further and is not implemented.

Estimated allocated bytes are shown. Observation-based protection cannot exclude a process that starts after the final check.
