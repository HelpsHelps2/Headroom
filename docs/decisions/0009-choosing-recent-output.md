# 0009 Choosing to remove recent output

Status: accepted. Narrows the inactivity rule in 0002 for manual cleanup only.

## Context

On the maintainer's machine most large worktrees are kept, and the commonest reason after live processes is output written within the keep window. Under disk pressure a person needs to clean a worktree they know is finished without waiting a day, and the interface offered no way to do it. The other protections exist because Headroom cannot tell whether the output is in use or rebuildable; the keep window is different, because the person knows whether they are done with a worktree.

## Decision

A person can select worktrees in the Worktrees tab. Stale worktrees and worktrees kept only by the keep window are selectable; every other reason locks the row.

- `Artifact.waiting` is true when the keep-window reason is the only reason an artifact is kept.
- `Engine.plan(paths:skippingWait:)` accepts waiting artifacts for the chosen paths. The plan records them in `CleanupPlan.skippingWait`, and `execute` applies the same rule to the fresh inspection immediately before deletion. Live activity, Cargo build locks, pins, worktree locks, tracked content, and unexpected content still apply, and the folder's identity, size, file count, and latest write must match the review, so a build that writes after review stops the deletion.
- Automatic cleanup never skips the keep window.
- History records that the folder was removed before the keep window ended. `headroom-cli clean --now` does the same for listed paths.
- For a worktree held by a process, the context menu can ask that process to quit after confirmation: `NSRunningApplication.terminate()` for apps, `SIGTERM` otherwise. The worktree becomes selectable on the next scan if nothing else keeps it.

## Consequences

Removing recently built output can cost a rebuild or reinstall the person chose to accept. The review screen labels these lines "built recently" and says how many were chosen early. Folders holding data, such as a Cargo `target` with `pgdata`, remain impossible to select.
