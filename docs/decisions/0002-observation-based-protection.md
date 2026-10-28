# 0002 Observation-based protection

Status: accepted.

## Decision

Use observations of activity and protections. Do not require build wrappers, resource leases, or agent integrations. Preserve a candidate when observations are incomplete, unavailable, stale, or contradictory.

Relevant signals include processes using a worktree or output, open files, recent writes, actual build-lock state where supported, Git worktree locks, and user protection. An observed idle shell, editor, language server, or development server using the worktree protects it initially.

The inactivity default is 24 hours, configurable. Newly discovered directories require observation before automatic eligibility. Absence of an observed process and old timestamps alone do not prove task completion.

## Reason

The product must work with existing development workflows after simple folder-level setup. Required coordination protocols were considered and explicitly rejected for the first version.

## Consequences

Protection is best effort. Revalidation narrows but does not eliminate the interval in which an uncoordinated process can begin using output. Filesystem traversal protections also do not provide universal exclusion against concurrent same-user writers.

A Git worktree lock is a preservation signal, not a compiler lock. A lock file's presence is not equivalent to an actively held operating-system lock. Lock inspection must be adapter-specific and validated.

Inspection failure must never be converted into a negative activity finding. A service restart, sleep interval, missed observation, or permission change must not silently count as proven inactivity. Define conservative handling in the observation prototype and test it.

Low storage never relaxes protection or authorizes killing processes. Expose why an item is preserved so false positives can be investigated without weakening the default policy.

## Reference

[Git worktree documentation](https://git-scm.com/docs/git-worktree).
