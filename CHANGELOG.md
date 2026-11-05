# Changelog

## 0.5.0

- Low disk space alerts. When free space falls under the level you choose (50 GB by default), Headroom sends a notification saying how much build output can be cleaned. It alerts once, then again only if free space halves or a day passes. Choose the level or turn alerts off in Settings.
- **Clean right away when low**, off by default. With automatic cleanup on, low space starts a cleanup without waiting for **Clean at most every**, largest folders first, until free space reaches twice the alert level. It uses the same auto folders, unused time, and protections as any automatic run.
- Settings and the Disk screen now say so when automatic cleanup is on but no folder is set to auto, because nothing gets cleaned in that state.

## 0.4.0

- Remove whole worktrees whose work is already merged. The new **Merged** filter on the Worktrees tab offers one only when its commits are in the default branch, `main`, or `staging`, or part of a pull request merged into one of them; it has no uncommitted changes; and nothing has used it for 7 days. Removal always follows your review and never runs automatically.
- Every worktree Headroom keeps is listed with its reason, and **The rules** shows each rule with how many worktrees it keeps right now.
- Branches and commits stay. History has a **Restore** button that recreates a removed worktree. Ignored files can't be restored: the review names `.env` files, and worktrees with other ignored files start unchecked.
- A worktree holding another worktree or repository in its folders stays.
- Merged pull requests are read with your own GitHub CLI (`gh`) if you have it. Without it, or offline, only branches are checked and the rest stay.
- `headroom-cli worktrees` reports each worktree's verdict and reason.

## 0.3.2

- Automatic cleanup runs much more often. Waiting for a folder to go unused and watching it for activity now happen at the same time, so a folder is cleaned about one wait after its last use instead of two.
- Sleeping the Mac no longer restarts the wait, as long as Headroom keeps running. Quitting Headroom still restarts it.
- A check with nothing ready no longer uses up the schedule. Headroom checks every 5 minutes and cleans as soon as a folder qualifies, at most once per interval.
- Settings has 1 h and 2 h choices for both timers. "Idle at least" is now **Clean when unused for**: no builds, installs, or open files in the project for that long. "Run every" is now **Clean at most every**.

## 0.3.1

- The sweep shows progress inside each folder. The freed total and the ring count up as files are removed, the current folder fills as it goes, and the line under the status says whether Headroom is checking the folder or removing it. Large Cargo `target` folders no longer look stalled.
- A finished sweep shows what it reclaimed with a check mark, or says the cleanup failed. The Disk screen shows the new free space right away instead of the old total while it rescans.
- The outer ticks on the ring move only while Headroom is scanning or cleaning.

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
