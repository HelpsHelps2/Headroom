# Changelog

## 0.2.0

First public build.

- Menu bar utility with a disk ring, plan review, worktree graph, live sweep, and history, in light and dark appearances.
- Removes stale `node_modules` and Cargo `target` folders from idle Git worktrees. Source, branches, lockfiles, worktrees, and shared caches are never touched.
- Every folder is checked again for open files, running builds, locks, and changes immediately before deletion.
- First launch suggests folders that contain worktrees (T3 Code, Codex, Cursor, Conductor, Claude Code) and common code folders.
- Optional automatic cleanup, off by default and opt-in per folder.
- Bundled `headroom-cli` for scripting.

Requires macOS 26 on Apple Silicon.
