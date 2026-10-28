# 0004 Planned cleanup and scheduling

Status: accepted.

## Decision

Use one pipeline for manual and scheduled cleanup: discover, inspect, plan, authorize, revalidate, execute, record. One worker owns destructive execution. Plans enumerate exact resources and reasons, rather than broad shell removal commands.

Offer manual cleanup and an optional configurable schedule. Background operation is explicitly enabled and visible. Version one defers disk-pressure-triggered deletion and free-space recovery targets.

Permanent deletion is available only for authorized verified generated output. Rebuilding is the recovery path. Do not present a deletion history as an undo facility or moving files to Trash as immediate storage recovery.

## Consequences

Pins, exclusions, activity, identity, ownership, and current authorization are checked again immediately before execution. Changed candidates are skipped. Persist execution intent and per-candidate outcomes so interruption produces a partial result rather than a false success.

After a crash, re-inspect incomplete operations; never resume an old deletion plan blindly. Use single-run coordination across the worker and any future command-line clients. A pause stops new destructive units promptly and reports any unit already in progress.

Schedules must handle sleep, logout, service disablement, and clock changes without overlapping jobs or replaying a backlog of missed deletions. Propose at most one fresh evaluation after a missed interval; validate this behavior before release.

Keep successful routine runs quiet. Surface persistent permission failures, service failures, and low-space conditions the app cannot resolve.
