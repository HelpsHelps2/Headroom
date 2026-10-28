# 0008 Headroom utility interface

Status: accepted. Supersedes the character and window layout in 0005; its accessibility and honesty commitments stay in force.

## Decision

The product is named Headroom. It is a menu bar utility with one narrow window (344 × 620 points), in the shape of a VPN client: a disk ring with one primary action, and tabs for Disk, Worktrees, and History. The visual language is aimed at developers: monospace figures, Git-graph and diff metaphors, and a single amber accent on neutral surfaces. The woodland character and illustration are removed. Light and dark appearances follow the system.

- **Disk:** the ring shows used space, stale build output (amber), and free space. The center button opens a review of everything eligible. A one-line plan summary sits under the ring.
- **Review:** the plan is shown as a diff grouped by worktree. Each line can be excluded. Kept folders list the reason. The plan can be copied as a `headroom-cli` command.
- **Worktrees:** each repository's worktrees appear as a branch graph with idle time, size, and the primary kept reason.
- **Sweeping:** the ring drains as folders are removed. A folder that becomes active mid-run is skipped and logged. "Stop after this folder" cancels between folders.
- **History:** reclaimed space this month, a 14-day free-space chart from samples taken at every scan, and each run with what it skipped.

The design references are `docs/design/utility-concepts.html` and `docs/design/utility-round-2.html`.

## Consequences

Pressure state still never changes cleanup authority. Turning on automatic cleanup requires an explicit confirmation describing permanent deletion. Controls are drawn in SwiftUI so the window can be captured in demo mode (`--demo --snapshot <dir>`) for review in both appearances.
