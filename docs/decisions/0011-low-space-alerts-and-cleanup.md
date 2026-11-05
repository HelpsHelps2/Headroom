# 0011 Low-space alerts and cleanup

Status: accepted. Narrows the disk-pressure deferral in 0004 and the product brief.

## Context

Headroom's own history on the maintainer's Mac, October 28 to November 4, 2026: 567 GB reclaimed across 259 folders, every run started by hand, and free space below 10 GB in 114 samples, reaching 0.1 GB on November 3. A cleanup schedule that runs on a fixed interval, or a window someone has to open, does not keep up with agent workloads that consume tens of gigabytes between checks. That Mac also showed automatic cleanup switched on in Settings with no folder marked automatic, a state that can never remove anything.

## Decision

Add a free-space level, 50 GB by default and adjustable or off. Under it, Headroom sends a notification, the alert 0004 calls for when low space is not resolved. It alerts once, again if free space halves or a day passes, and starts over only after free space recovers to twice the level. A failed disk reading never counts as low.

Add **Clean right away when low**, off by default and never turned on by an update. With it on, a check that finds free space under the level may clean before **Clean at most every** is up. It stops at twice the level, largest folders first, counting only output on the volume being measured.

This trigger changes when and how much is cleaned, not what may be removed. Candidates must already qualify for automatic cleanup: folder marked automatic, schedule on and not paused, unused wait passed, and every protection clear. [0002](0002-observation-based-protection.md) still holds: low storage never relaxes protection or authorizes killing processes. The wait is not skipped, because skipping it is reserved for a person ([0009](0009-choosing-recent-output.md)). Whole worktrees stay review-only.

Say plainly when automatic cleanup is on but no folder is marked automatic, rather than changing the setting for the person.

## Consequences

Free space is read once a minute, which is cheap, while scans keep their existing schedule. Crossing the level starts one early scan and check, so a cleanup that resolves the problem stays quiet. Scans stay on their schedule until then, and observation requirements are unchanged, so on a Mac without automatic cleanup enabled a low-space event alerts but cleans nothing.

The target is best effort. Sizes are estimates, and if a run falls short the next check, about five minutes later, measures again and continues. A run that removes nothing waits an hour before trying again so History does not fill with repeated skips.

Headroom can only clean what its protections allow, so low space can persist with folders held by live processes. The notification says so rather than escalating.

macOS asks for notification permission the first time an alert is needed. If it is denied, Settings says so; alerts are not delivered any other way.
