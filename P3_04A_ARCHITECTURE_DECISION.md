# P3-04A: Pointer-Primary Interaction Architecture

## Decision

TouchBridge moves from `HID → gesture recognition → AX semantic tap → pointer fallback` to `HID → gesture recognition → interaction intent → delivery policy/router`.

Ordinary qualified taps use transient pointer delivery by default. Accessibility is an optional enrichment layer and remains available for explicit semantic-only diagnostic comparisons. AX hit-test results, roles, and permission state do not qualify or suppress pointer-primary taps.

## Evidence

The P3-03 implementation coupled ordinary taps to AX discovery and treated pointer delivery as a fallback. AX exposure varies across custom UI, static text, groups, and web content; requiring actionable AX nodes therefore made ordinary taps depend on app accessibility metadata. The transient pointer mechanism already exists and can be selected without duplicating its low-level event implementation.

## Runtime and compatibility

Gesture arbitration emits interaction intents. The delivery router selects a concrete tap mechanism; direct two-finger scroll and momentum retain their existing lifecycle and engine. Core input/gesture readiness is reported separately from AX enrichment availability.

The default is pointer-primary. `--tap-backend semantic-only` selects diagnostic semantic delivery. Existing `--tap-backend semantic` and `--tap-backend transient-pointer` values remain accepted.

## Scope and follow-up

This revision establishes the architecture and does **not** certify transient-pointer physical correctness. Cursor transaction timing and intermittent relocation verification remain open. P3-04B must focus on pointer transaction acknowledgement and correctness, including cursor restoration, before physical correctness is claimed.
