# 0001 Native Mac foundation

Status: accepted.

## Decision

Use SwiftUI with AppKit where necessary, a shared Swift core, SQLite for local state, and one cleanup worker running as the logged-in user. Start with Apple Silicon and a published macOS support window. Provide a native app first; keep the core suitable for a later CLI.

The core must be testable without the interface. Separate artifact adapters, platform inspection, policy evaluation, persistence, and execution. Keep these modules in one repository and one release train.

## Reason

The initial product is Mac-only. A single-language implementation reduces build and contribution complexity while keeping native accessibility, filesystem access, and background services available. Cross-platform frameworks and a Rust bridge add maintenance without an established requirement.

## Consequences

Keep interface state out of the policy engine. Require measured evidence before adding another implementation language. Use bounded background work and cancellation so scans do not block the main actor.

Exact deployment target, SQLite wrapper, and IPC implementation are technical-validation choices. The proposed implementation uses authenticated XPC and a bundled launch agent registered through SMAppService. App and worker protocols must be versioned.

## Reference

[Apple SMAppService documentation](https://developer.apple.com/documentation/servicemanagement/smappservice).
