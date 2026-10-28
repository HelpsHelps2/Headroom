# Security policy

Headroom deletes files. A bug that deletes something it should have kept is a security issue, even without an attacker.

## Reporting

Report privately through GitHub: **Security → Report a vulnerability** on this repository. Do not open a public issue for:

- anything deleted that should have been kept: source, a lockfile, a worktree, a shared cache, or a folder that was in use
- a way to make Headroom follow a symbolic link, leave its watched folders, or delete outside a build-output folder
- a way for a repository's own contents to change what Headroom deletes

Include the macOS and Headroom versions, the kept reasons or history entry involved, and steps that reproduce it on a disposable project. Redact personal paths and repository names. Please do not send source code, tokens, or raw process lists.

You will get an acknowledgement within a few days. Fixes for deletion-safety issues ship before other work.

## Supported versions

Only the latest release receives fixes.
