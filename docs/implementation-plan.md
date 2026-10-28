# Implementation plan

The first release includes working reviewed cleanup and optional scheduled cleanup. Earlier milestones validate components; they do not substitute for that product outcome.

## Milestone 0 Establish the repository

Create the Swift package and app/worker targets with a small fixture-based test harness. Select the exact macOS deployment target after inspecting the available SDK and checking the agreed support window. Add the canonical Apache-2.0 license, ownership attribution, contribution guidance, and dependency notices before external contributions.

Keep local development possible without production release credentials. Choose the public project name and bundle identity before publishing signed builds. Defer the production updater until there is a signed release path, but reserve compatible app/worker versioning now.

Acceptance: a documented command runs core tests; app and worker build; the repository clearly states supported platforms and contains no production secrets.

## Milestone 1 Validate the highest-risk mechanisms

Build focused prototypes for:

- Process and open-reference inspection under realistic user permissions, including compiler descendants, idle shells, editors, language servers, and permission denial.
- Actual Cargo lock behavior across the intended supported toolchain range; distinguish held locks from leftover lock files.
- Discovery of ordinary Cargo targets, configured external output, sccache, registry storage, and shared ownership.
- Contained filesystem traversal under symlinks, renames, identity changes, permissions, and concurrent activity.
- App/worker permission behavior and background registration without an administrator helper.

Use synthetic temporary projects for mutation tests. Read-only inventory of real development folders may validate discovery. Never use a user's live worktrees as destructive test fixtures.

Acceptance: record which observations are available, which failures become unknown, and which layouts remain unsupported. Demonstrate protection of configured shared caches. Document the remaining race with unrelated builds explicitly. Choose the supported automatic-cleanup cases from evidence rather than making universal claims.

## Milestone 2 Implement the core vertical slice

Implement selected roots, worktree discovery, artifact identity and ownership, observations, durable protections, and a pure policy evaluator. Create exact plans with reasons and policy revisions. Add a worker that executes one authorized fixture candidate after revalidation and records success, skip, or partial failure.

Acceptance: a private inactive Cargo output can be removed through the worker; active, pinned, shared, uncertain, tracked-content, and changed candidates remain protected. Source and shared cache fixture sentinels remain intact. Tests exercise actual filesystem behavior, not only mocked return values.

## Milestone 3 Build the reviewed-cleanup experience

Create the searchable native project list, progressive scan state, detail explanations, root settings, pins/exclusions, and cleanup review. Show estimates separately from observed free-space changes. Surface incomplete inspection and stale results.

Explore the character and environment in representative states. Test long paths, dense lists, large protected directories, accessibility, keyboard use, Reduce Motion, and inactive-window performance.

Acceptance: a user can explain why each candidate is eligible or protected, select eligible output, understand permanent deletion and rebuild consequences, run cleanup, and inspect its actual result. Pausing or cancelling reports any action already in progress accurately.

## Milestone 4 Add simple optional scheduling

Add folder-level automatic-cleanup opt-in, configurable schedule, configurable inactivity defaulting to 24 hours, background registration, pause, and service health. Use the same worker and policy pipeline as manual cleanup. Preserve a fresh-observation requirement for newly discovered or uncertain resources.

Defer pressure triggers, recovery targets, process termination, and selective Cargo pruning. Present storage pressure visually without changing cleanup authorization.

Acceptance: enabled schedules run with the window closed while the user is logged in. Tests cover sleep/wake, clock changes, service restart, disabled background operation, missing volumes, revoked access, and duplicate clients. Missed intervals do not launch overlapping or stale deletion runs. Routine success remains quiet; actionable failures are visible.

## Milestone 5 Prepare the public release

Run the destructive correctness suite on the supported macOS matrix and a physical APFS system. Verify identity handling, clone accounting expectations, containment, shared-cache preservation, and crash reconciliation. Measure scanning against a large fixture corpus; keep CPU, memory, I/O concurrency, and history storage bounded.

Verify signed and notarized installation, worker registration, app relocation, updates, uninstall, and permission instructions. Keep release credentials out of pull-request jobs. Review dependencies and first-party art licenses. Establish private vulnerability reporting and designated review for destructive code.

Acceptance: the released app meets the agreed manual and automatic workflows; publishes accurate protection limits and supported layouts; and can be built by contributors without the official signing identity. No release claim promises guaranteed interruption-free observation-based cleanup.

## Required failure scenarios

These are release gates rather than optional broad test expansion:

- An active compiler, terminal, editor, or server is observed using a candidate.
- A process begins after inspection; the test documents detectable cases and the residual race without claiming universal exclusion.
- A candidate or parent is renamed, replaced, symlinked, or moved across authorization boundaries.
- Two worktrees reference the same output, or selected roots overlap.
- A project changes output configuration after a plan is created.
- A protected shared compiler cache is inside a selected scan root.
- A scan or tracked-content inspection is incomplete or denied.
- A newly discovered old directory has insufficient observation history.
- The worker crashes before, during, or after a filesystem mutation and before its database result is committed.
- Pins or policies change while a plan awaits execution.
- The app and worker versions disagree or inventory is lost.
- Storage accounting is affected by hard links, APFS clones/snapshots, or unrelated writes.

## Deferred features

Whole-worktree and branch retirement; Intel or non-Mac support; additional build ecosystems; required agent integrations; arbitrary executable plugins; selective Cargo-internal trimming; pressure-triggered cleanup; automatic free-space recovery targets; hosted accounts; and funding mechanics.

Deferred does not mean prohibited. A new feature needs a concrete user case, a decision record when it changes the foundation, and tests appropriate to its deletion authority.
