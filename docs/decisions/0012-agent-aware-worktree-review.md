# 0012 Reviewed worktree eligibility and optional agent context

Status: accepted. Narrows the age rule for manual whole-worktree removal; automatic output retention is unchanged.

## Decision

Merged, clean, inactive linked worktrees can be reviewed immediately, independent of coding tool. Seven days is a default-selection threshold, not a deletion prerequisite. Recent work starts unchecked. Explicit completion after last use from every known owner can recommend recent work. Unknown completion and unrecognized ignored files require explicit selection. Active sessions block both output cleanup and whole-worktree removal.

Optional read-only adapters share an `AgentContext` of path, provider, active/finished/unknown state, and completion timestamp. They cannot authorize deletion. T3 supplies explicit settlement/archive metadata and run state, with child lineage resolution and project-root fallback. Codex supplies cwd and archive metadata. Claude Code supplies registered session cwd and PID; neither idle responses nor dead PIDs imply completion. Existing process observation remains required for all providers. Paths are canonicalized and overlapping ownership is conservative.

No integration is required. Missing stores produce no evidence. Installed stores with unsupported schemas, malformed metadata, or read failures fail closed. Only metadata is queried; conversation content, credentials, and agent database writes are excluded. Schema adapters are intentionally bounded and fixture tested. Future providers implement the same evidence contract.

## Review and execution

`needsLook` includes recent use and unknown completion, as well as ignored files. The UI states the reason and starts these rows unchecked. The existing explicit-selection plan set covers all review requirements. Execution reads fresh agent metadata and reapplies Git, process, pin, lock, nesting, ignored-file, and merge checks. A newer last-use timestamp or changed agent ownership fingerprint invalidates the review. Whole-worktree removal remains manual, uses Git without force, and preserves restore refs.

## Limits

Provider formats are local implementation details and can change. Claude installations without session registration files rely on the universal process checks; no transcript inference or synthetic completion is attempted. Legacy T3 metadata cannot establish completion. Unknown or unsettled owners can suppress recommendations even after an age threshold; users may still explicitly review eligible work. This change adds no new artifact types and does not weaken automatic cleanup retention or shared-cache protection.
