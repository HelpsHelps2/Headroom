# 0003 Artifact ownership and cache preservation

Status: accepted.

## Decision

Version one cleans complete, verified, private Cargo output directories from eligible inactive worktrees. Preserve shared compiler caches, Cargo registry/download storage, shared build output, unknown files, source, branches, and whole worktrees.

Model artifact ownership explicitly. One physical artifact root may have several owners or appear through overlapping scan roots. A protected or unresolved owner prevents automatic cleanup. Configured output outside an approved root requires explicit scope inclusion; discovery alone does not authorize it.

## Reason

Shared caches can reduce rebuild cost and are intentionally valuable. Their purpose differs from disposable output duplicated across abandoned worktrees. Whole private output directories offer a smaller initial correctness surface than selective deletion of Cargo's internal artifact graph.

## Consequences

Read relevant Cargo configuration and account for known overrides. Build-command environment overrides may remain unknowable; unknown ownership must remain protected. Never assume that every directory named target is generated, or that all output lives below a worktree.

Establish positive artifact evidence and detect tracked or unexpected contents. Unknown layouts become review findings; confirmation is not permission to turn an unsupported layout into automatic cleanup.

The initial adapter set is built in. Adapters provide discoveries, evidence, and supported action descriptions; the central policy and executor retain authority. Repository-local configuration cannot grant deletion permission or weaken global user protections.

## Reference

[Cargo build cache documentation](https://doc.rust-lang.org/cargo/reference/build-cache.html) describes configurable output roots and notes that internal build-directory layout can change.
