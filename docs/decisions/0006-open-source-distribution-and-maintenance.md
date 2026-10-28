# 0006 Open-source distribution and maintenance

Status: accepted product commitments; release-process details are implementation recommendations.

## Decision

Release the complete local feature set as open source under Apache-2.0. Permit commercial reuse under its terms. Require no account, subscription, or hosted service for core operation. Distribute official signed and notarized Mac downloads.

Initial support is Apple Silicon and the current and previous major macOS releases at first release. Publish exact versions and a deliberate maintenance policy. Intel support is deferred.

## Maintenance recommendations

- Add the canonical license, ownership attribution, dependency notices, and first-party asset licensing before public distribution or accepting external contributions.
- Document local builds and tests that do not need production signing credentials.
- Keep release signing credentials isolated from untrusted contributions. Pin release automation dependencies and require designated review for deletion, permissions, and update-path changes.
- Provide contribution guidance, maintainer responsibilities, a private security-reporting channel, and a bounded compatibility matrix.
- Version configuration, database migrations, adapter evidence, and IPC. Incompatible components must disable cleanup rather than guess.
- Keep diagnostics local by default. Make export user-initiated and redact identifying paths and repository details where possible.
- Retain clear instructions for pausing, unregistering background operation, and uninstalling the app.

Official name, signing identity, bundle identifier, funding, and distribution hosting remain unassigned. Do not fabricate them in early scaffolding.

## References

- [Apache-2.0 license](https://www.apache.org/licenses/LICENSE-2.0).
- [Apple Developer ID distribution](https://developer.apple.com/developer-id/).
- [Sparkle documentation](https://sparkle-project.org/documentation/), a candidate for signed application updates.
