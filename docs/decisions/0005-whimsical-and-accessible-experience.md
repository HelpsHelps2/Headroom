# 0005 Whimsical and accessible experience

Status: accepted; the window layout and character are superseded by [0008](0008-headroom-utility-interface.md).

## Decision

Use a native window with a searchable project list and explanation inspector, plus an optional menu-bar companion. Give the app a prominent whimsical character and environment that respond to storage pressure and cleanup results.

Visual pressure state does not determine cleanup permission. The same action labels and protections apply in every visual state.

## Consequences

Create a visual state model separate from cleanup policy. Include comfortable, constrained, busy, paused, and attention-needed states without implying that every storage problem is dangerous or immediately removable.

Use text alongside color, accessible contrast, keyboard operation, VoiceOver labels, and reduced-motion alternatives. Keep paths and deletion consequences precise. Avoid frantic motion and animations that consume resources while the window is hidden.

Validate the design with real-sized paths, many projects, incomplete scans, protected large directories, and partial failures. The experience must explain why space cannot be reclaimed as clearly as it celebrates successful cleanup.

The name, mascot, palette, and exact transitions remain deferred creative choices.
