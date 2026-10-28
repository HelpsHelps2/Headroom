# Architecture

The architecture implements the accepted [decision records](decisions/README.md). Concrete API and library selections below are proposed until validated. This distinction keeps user-approved product behavior separate from engineering assumptions.

## Components

The SwiftUI app and future CLI are clients. They request discovery, inspection, planning, and execution from a per-user worker. The worker owns cleanup coordination and durable operation history.

Use a shared Swift package with small modules:

- **Domain:** immutable models, policy inputs, eligibility evaluation, and reason codes.
- **Discovery:** selected roots, repository/worktree discovery, artifact adapters, ownership resolution.
- **Mac inspection:** filesystem identity, metadata, processes, open references, locks, permissions, and volume availability.
- **Planning and execution:** exact action plans, current-policy validation, bounded execution, partial results.
- **Persistence:** SQLite schema and migrations, inventory, observations, protections, plans, and history.
- **Service:** authenticated local IPC, background registration, scheduler, run coordination, pause, and cancellation.

Avoid separate packages or services for every type. These are testable responsibility boundaries in one repository. The domain policy must not depend on SwiftUI, SQLite calls, or subprocess execution.

Proposed IPC is authenticated XPC with a versioned request/response protocol. Authenticate clients, validate request scope independently, and make the worker reject stale plans or incompatible clients. Running with the same user identity is not by itself sufficient justification to accept arbitrary deletion requests.

## Data model

- **ScanRoot:** user-authorized directory identity, resolved location, volume identity, scan and automation settings.
- **Repository and Worktree:** Git common-directory identity, worktree identity, registration, lock information, and observed activity.
- **ArtifactRoot:** filesystem identity, location, adapter and evidence version, resource class, owner set, measured bytes, inspection completeness.
- **Observation:** signal, resource identity, result, time, inspection capability, and uncertainty. Distinguish absent, present, and unavailable.
- **Protection:** user pin or exclusion, built-in protected class, scope, and reason. Preserve independently of rebuildable inventory.
- **CleanupPlan:** exact candidate identities, ownership/evidence snapshot, policy revision, authorization scope, estimated bytes, and expiry.
- **Execution:** operation identity, intent, per-candidate states, skip reasons, errors, and before/after capacity observations.

Paths are display and lookup values, not permanent identities. Resolve renames, overlapping roots, volumes, aliases, and shared artifact ownership conservatively. Symlink targets do not inherit deletion authorization from the link's location.

## Eligibility

Automatic eligibility requires all of the following:

1. The root is explicitly enabled for automatic cleanup and permanent generated-output deletion.
2. The artifact is positively identified as a supported private generated root, with no conflicting ownership or unexpected content.
3. No pin, exclusion, Git lock, protected resource class, or observed activity applies.
4. Inspection capabilities and observations are sufficient and fresh under a documented policy.
5. The configurable inactivity window is satisfied by observation history, not only an old directory timestamp.
6. Immediate pre-execution revalidation still passes.

Manual cleanup uses the same protections. Explicit review may supply authorization for a newly discovered inactive candidate without waiting out automatic observation, but does not bypass active-work protections, unknown ownership, or unsupported content.

The final filesystem operation remains vulnerable to uncoordinated activity starting after inspection. Neither repeated checks nor an app-internal mutex supplies a lock that every external compiler honors. Document this residual risk and validate behavior under races; do not claim a zero-interruption guarantee.

## Filesystem execution

Keep deletion in a narrow implementation with explicit approved roots. Avoid shell interpolation and broad recursive removal commands. Establish object and volume identity, do not follow symlinks during deletion, and evaluate descriptor-relative traversal where appropriate. Verify how the selected APIs behave when directories or parents are renamed during execution.

A path-safety check is not proof of artifact disposability. An exclusive app cleanup lock is not an external build lock. A read-only inspection command is not necessarily harmless if it invokes repository-defined hooks, filters, helpers, or configuration. Use a controlled subprocess environment and fixed argument arrays; audit Git/Cargo command behavior before using it during discovery.

Never run a build to identify a cache. Do not execute repository-provided cleanup scripts in version one. If tracked-file or content verification cannot complete, preserve the candidate.

Journal operation intent before mutation and record each outcome. Database transactions cannot make filesystem deletion transactional. Recovery reconciles the filesystem and history without assuming either is the complete truth.

## Inventory and storage accounting

Discover artifact boundaries before deep measurement. Prune dependency/output subtrees during discovery, bound concurrent I/O, stream results, and support cancellation. Include hidden development roots when explicitly selected. Cloud-managed, remote, or unavailable volumes need capability classification; unsupported cases remain review-only.

Cache inventory in SQLite. Use filesystem events as invalidation hints with periodic reconciliation and required rescans after dropped events. An event stream is neither an authorization source nor complete activity history.

Avoid double-counting overlapping paths and hard-linked identities. Report logical or allocated estimates with clear units and provenance. APFS clone/snapshot sharing means allocated size is not a promise of recoverable space. Report observed free-space change separately, acknowledging unrelated concurrent disk activity.

Apply retention limits to history, diagnostics, and rebuildable inventory. Inventory loss must preserve user settings and protections and reset automatic eligibility until required observations are restored.

## Permissions and lifecycle

Run as the logged-in user with selected roots. The proposed distribution build is outside App Sandbox, subject to normal macOS privacy controls; validate the actual app and worker permissions before committing to that packaging implementation. Keep Full Disk Access optional and purpose-specific. Permission denial remains visible and blocks affected cleanup.

Prototype a bundled launch agent registered through SMAppService. Show real registration and service state. Test app moves, updates, mismatched worker versions, disabled login items, logout, reboot, sleep, and revocation. Cleanup is disabled during incompatible component states.

Background execution is opt-in. A missed schedule results in at most one fresh eligible evaluation, not a queue of historical deletion attempts. Define monotonic elapsed-time handling, wall-clock schedule behavior, and conservative restart/sleep treatment during implementation.

## Visual state

The interface consumes domain reasons and a separate presentation model. Storage pressure can affect character expression, environment clutter, and color. It cannot broaden the cleanup set. Normal project controls and action meanings remain consistent across visual states.

## References

- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
- [Apple sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), relevant to the permissions spike and any future sandbox build.
- [Apple FSEvents rescan requirements](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).
- [Apple APFS overview](https://developer.apple.com/documentation/foundation/about-apple-file-system).
- [Cargo output configuration and layout](https://doc.rust-lang.org/cargo/reference/build-cache.html).
- [Git worktree behavior](https://git-scm.com/docs/git-worktree).
