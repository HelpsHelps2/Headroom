# Changelog

## 0.3.0

- Headroom updates itself. It checks once a day, downloads new versions in the background, and installs them when it is idle. Updates must be signed with the project key and Developer ID. Settings has the switch and a Check Now button.
- Worktrees opens on every repository and every worktree, with a branch graph per repository. Pick one repository or filter to Stale or Kept from there.
- Check worktrees to clean just those. Worktrees kept only because they were built in the last 24 hours can be checked and cleaned right away; in-use and data folders stay locked. Every folder is still checked again just before deletion.
- **Clean now** on the Disk screen and in the menu bar reviews everything that can go today, including builds from the last 24 hours. It's the main button when nothing is stale yet.
- Right-click a worktree held open by a process to quit that process.
- `headroom-cli clean --now` removes listed folders built within the keep window.
- The scan arrow spins at the top of every tab while a scan runs.
- The installer window shows where to drag Headroom, in Headroom's colors.

## 0.2.0

First public build.

- Menu bar utility with a disk ring, plan review, worktree graph, live sweep, and history, in light and dark appearances.
- Removes stale `node_modules` and Cargo `target` folders from idle Git worktrees. Source, branches, lockfiles, worktrees, and shared caches are never touched.
- Every folder is checked again for open files, running builds, locks, and changes immediately before deletion.
- First launch suggests folders that contain worktrees (T3 Code, Codex, Cursor, Conductor, Claude Code) and common code folders.
- Optional automatic cleanup, off by default and opt-in per folder.
- Bundled `headroom-cli` for scripting.

Requires macOS 26 on Apple Silicon.
