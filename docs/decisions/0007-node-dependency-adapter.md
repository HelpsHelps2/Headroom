# 0007 Node dependency adapter and Git-guided discovery

Status: accepted. Narrows the "additional build ecosystems" deferral in 0003 and the implementation plan.

## Context

A read-only inventory of the maintainer's agent worktrees on October 28, 2026 found 398 Git worktrees with 137 build-output folders and 133 GB of output: 110 `node_modules` folders and 26 Cargo `target` folders. A Cargo-only adapter would leave most of the folders that cause the daily cleanup unaddressed. The same inventory hit the 100,000-directory discovery limit before finishing a single repository's worktrees.

## Decision

Add a built-in `node_modules` adapter beside the Cargo adapter. It reports a folder as eligible only with all of the following, in addition to the shared policy (inactivity, live activity, pins, locks, tracked content, containment):

- `package.json` beside the folder, and a lockfile (`package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`) in that project or an ancestor inside the same worktree.
- Git reports the folder as ignored (`git check-ignore`) and tracking nothing inside it.
- Positive evidence of a package-manager install: a known install marker (`.package-lock.json`, `.modules.yaml`, `.yarn-state.yml`, `.yarn-integrity`, `.pnpm`) or installed packages with their own `package.json`.

Install trees legitimately contain symbolic links (`.bin`, workspace packages). For this adapter only, measurement counts links without following them and deletion removes the links themselves with `unlinkat`; destinations are never opened. Files with more than one hard link (pnpm and Bun stores) are not counted as reclaimable, because deleting this copy does not free them. Package caches (`~/.npm`, `~/.bun`, pnpm and Yarn stores) join the never-touched list.

Discovery walks each watched folder only until it reaches a Git worktree, then asks Git for manifest locations (`ls-files --cached --others --exclude-standard`) instead of walking the source tree. `git worktree list` adds linked worktrees that live elsewhere under a watched folder, including inside another worktree's ignored folders. Results are cached per worktree until its index or HEAD changes. Candidates are inspected by four concurrent workers.

## Consequences

Folders without the evidence above stay protected and are explained, including a Cargo `target` holding a Postgres data directory (`pgdata`), which the inventory found in several worktrees. Small folders under 1 MB (for example a `node_modules` holding only a Vite cache) are not listed in the interface.

A new manifest that is untracked and never staged is found once the worktree's index changes. Nested repositories that are not worktrees of a discovered repository are not searched.

Additional ecosystems (SwiftPM `.build`, Xcode DerivedData, `.next`, `dist`) remain deferred and each needs its own evidence rules and fixture tests.
