# P3-04D AX Semantic Scroll Feasibility — Checkpoint

Date: 2026-09-27
Status: Environment blocked before target-window inspection

## Scope

This is a diagnostic checkpoint only. P3-04B tap behavior was not changed as part of this probe. No scroll gesture, AX value write, application activation, or cursor movement was attempted.

## Host evidence

Built the current diagnostic branch successfully with:

```text
swift build --scratch-path /private/tmp/touch-bridge-build
Build complete! (21.84s)
```

Build emitted an existing Swift 6 concurrency warning in `RollbackReproducer.swift:293`.

Running `TouchBridgeProbe --inspect-only` reported:

```text
Connected Displays (0)
No external display identified
USB2IIC_CTP_CONTROL found (VID 0x1A86, PID 0xE5E3)
```

Starting the live diagnostics mode exited with `No external touchscreen display discovered.` The desktop UI bridge also returned an empty native-app inventory and no browser tabs. As a result, there was no screen coordinate or live app window to hit-test.

## Requested app matrix

| Surface | AX hierarchy and scroll capabilities | Direct AX adjustment | Cursor / focus result | Responsiveness |
| --- | --- | --- | --- | --- |
| Finder, main display | Not inspected: no connected displays or target coordinate | Not attempted | Not measured | Not measured |
| Finder, external touch display | Not inspected: no connected displays or target coordinate | Not attempted | Not measured | Not measured |
| Native AppKit (TextEdit or equivalent) | Not inspected: no live app window | Not attempted | Not measured | Not measured |
| Safari | Not inspected: no live app window or browser tab | Not attempted | Not measured | Not measured |
| Chromium-family browser | Not inspected: no live app window or browser tab | Not attempted | Not measured | Not measured |

No AX hit element, ancestor chain, scrollbar, writable `AXValue`, or actionable increment/decrement control was observed. This is missing test access, not evidence that the applications omit those capabilities.

## Classification and next architecture

Classification: **undetermined**. The evidence does not support AX1, AX2, AX3, or AX4. In particular, AX4 would incorrectly turn an unavailable target into a claim about application exposure.

No architecture recommendation can be selected from the requested comparison yet. Keep both product directions open: a fixed-point transient-pointer fallback with conditional restoration, and deeper native/driver investigation. Do not describe either as cursor-independent. Re-run this matrix on a host session with Finder windows on both displays and a connected external touch display; then collect the exact AX object, old/new value, focus/window state, pointer position, write latency and failure codes before judging responsiveness.

## Repository state at checkpoint

- Branch: `codex/p3-04c-cursor-independent-scroll` (still diagnostic)
- HEAD: `e4f403e`
- No commit or push made.
- Pre-existing P3-04C working-tree changes, including `p3_01_verification_evidence.json`, were preserved.
- This checkpoint file is the only file added for P3-04D.
