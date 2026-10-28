# Product brief

Status: accepted product direction, October 28, 2026.

## Problem and audience

Developers running coding agents accumulate many Git worktrees and large Rust build directories. Repeated manual cleanup interrupts development. The initial product must address this workload, including existing worktrees, without requiring individual worktree registration or changes to build commands.

Success means that, after folder selection and policy setup, eligible stale output can be cleaned automatically with minimal routine attention. An inventory-only application is a development milestone, not the completed first release.

## Version one

Users select development folders. The app discovers repositories, linked worktrees, and verified Cargo output within the approved scope. Users can search and inspect projects, protect individual projects, review a cleanup plan, and clean selected generated output.

Automatic cleanup is optional. Users enable it for selected roots and choose a schedule. Manual and scheduled execution use the same inspection, protection, and execution rules. Scheduled cleanup needs no recurring confirmation once its scope and permanent-deletion policy have been enabled.

The initial inactivity default is 24 hours and is configurable. Newly discovered output starts an observation period; old filesystem timestamps alone do not establish eligibility for automatic deletion. Manual review can authorize cleanup of newly discovered output after current protections pass.

Background operation is explicit and continues when the window closes, within the logged-in user's session. The app shows whether the service is enabled, working, paused, or blocked. Routine successful runs remain in history. Notifications focus on low space that remains unresolved, permission failures, and conditions needing attention.

## Preservation and deletion

- Preserve observed active worktrees, including relevant idle terminals, editors, language servers, and development servers when their use can be established.
- Preserve pinned projects, Git-locked worktrees, uncertain candidates, shared output, shared compiler caches, and Cargo registry/download storage.
- Clean complete, verified generated directories belonging exclusively to eligible inactive worktrees. Selective Cargo-internal pruning is deferred.
- Never infer disposability from a directory's name alone.
- Permanent deletion of authorized generated output reclaims storage; rebuilding is its recovery mechanism. History is an audit record, not an undo mechanism.
- Whole-worktree removal, branch deletion, source deletion, and terminating builds are outside version one.

Observation cannot provide an absolute guarantee against concurrent work. A process may start between the final inspection and deletion. The app must communicate its protection as conservative and best effort, and preserve candidates whenever inspection is incomplete or contradictory.

## Cache distinction

Shared reusable compilation caches are a protected resource class, separate from private worktree build output. Cleaning a private output directory can still require recompilation, linking, and regeneration even when a shared cache is retained.

The architecture interview verified one concrete example: the originating user's global Cargo configuration uses sccache, with a cache directory observed at `~/Library/Caches/Mozilla.sccache`; Cargo registry storage exists at `~/.cargo/registry`. No global Cargo output override was found in that bounded inspection. These are examples for fixtures and discovery design, not hardcoded assumptions about other users or project-specific configuration.

## Schedule scope

Version one offers manual execution and a configurable schedule. Disk-pressure thresholds, recovery targets, and emergency escalation are deferred. Pressure never overrides protection.

Scheduled runs operate on the authorized eligible set for their selected roots. Preservation comes from inactivity retention, exclusions, pins, and shared-cache protection. Automatic stopping at a free-space target belongs to the deferred pressure mode; version one must not claim that optimization.

## Experience and personality

A menu bar utility with one narrow window built around a disk ring and a single reclaim action, with Worktrees and History tabs ([0008](decisions/0008-headroom-utility-interface.md)). Show storage estimates, activity, protection, candidate reasons, and inspection freshness. Pressure presentation is independent of cleanup eligibility and schedule decisions.

Controls remain stable. Use literal action labels, readable paths, textual state descriptions, accessible contrast, keyboard navigation, VoiceOver, and Reduce Motion support. Avoid alarming language, deletion scores, or celebrations based on inflated estimated savings. Keep rendering inexpensive while the app is idle or hidden.

The name is Headroom. Palette and type follow the design references in docs/design.

## Support and openness

Initial support: Apple Silicon, with the current and previous major macOS releases at initial release. Publish explicit supported versions; review the moving support window with each major release rather than silently dropping support. Intel and additional operating systems are deferred.

Distribute signed and notarized official downloads. Full local functionality remains open source and works offline without an account or subscription. Apache-2.0 is the selected code license, including acceptance of commercial reuse under its terms. Funding and official branding are separate decisions.
