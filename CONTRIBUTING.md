# Contributing

Headroom is a native Mac development-storage tool. Read the product brief and accepted decisions in docs before changing behavior.

## Develop

Use Apple Silicon, macOS 26 or later, and Xcode 27 / Swift 6.4 for the currently validated toolchain. Open Package.swift in Xcode or use `bash scripts/test.sh` and `bash scripts/build-app.sh`. No release certificates or accounts are required for local builds. The package currently uses Swift 5 language mode; strict Swift 6 concurrency migration is tracked as hardening work.

## Changes

Keep policy independent of the interface. Add meaningful fixture tests for changes to ownership, activity, containment, scheduling, or deletion. Never use live developer worktrees as deletion fixtures. Do not broaden deletion based only on directory names or change unknown observations into inactive results.

Changes to destructive operations, permissions, dependency updates, and release signing require explicit maintainer review. Do not run repository-defined commands or scripts during discovery. Add adapters in the core; plugins cannot grant deletion permission.

Describe the resulting behavior, why it is needed, and how it was validated. Contributions are provided under Apache-2.0. Keep dependency and artwork notices accurate.

## Reporting issues

Include macOS and app versions, relevant protection reasons, and reproduction steps using a disposable project. Redact personal paths and repository names. Do not post source code, tokens, or raw process lists. Report anything deleted that should have been kept, or any way around the protections, privately as described in [SECURITY.md](SECURITY.md).
