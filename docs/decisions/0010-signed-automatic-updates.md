# 0010 Signed automatic updates

Status: accepted. Settles the update mechanism 0006 left open.

## Context

Headroom deletes files, so a fix to its protections only helps people once it reaches them. Before this decision, installed copies never learned about new versions. Headroom runs from the menu bar and rarely quits, so an update that waits for quit can wait for weeks.

## Decision

Use Sparkle 2, through Swift Package Manager, pinned in `Package.resolved`.

- The feed is `appcast.xml` on the latest GitHub release, so the release process stays a single upload and needs no other server.
- Updates must carry an EdDSA signature from the `headroom` key and the same Developer ID signature as the installed app. `SUVerifyUpdateBeforeExtraction` checks the signature before the DMG is opened.
- Checks run daily and downloads happen in the background by default (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`). People can turn automatic installs off in Settings.
- A downloaded update installs when Headroom is idle: no sweep or scan in progress and the app not in front. It never interrupts a cleanup. Otherwise it installs at quit or through **Restart to Update**.
- Scheduled checks never open an update window over other work (Sparkle's gentle reminders). With automatic installs off, the gear and the menu show the new version.
- Sparkle's XPC services are removed because Headroom is not sandboxed.

## Consequences

Losing the private update key strands installed copies; it must be backed up offline (see `docs/releasing.md`). Build numbers come from the commit count on `main`, so releases must be cut from `main`. Demo mode and builds without an update key, such as `swift run`, never check.
