# TouchBridge P3-03R — Direct Touch Interaction, Input Ownership & Kinetic Gesture Engine

**Date:** 2026-09-27  
**Milestone:** P3-03R (Direct Touch Interaction & Input Ownership)  
**Status:** TECHNICAL CANDIDATE (Awaiting Owner Review)  
**Host Hardware:** MacBook Pro 2019 Intel (`x86_64`)  
**Operating System:** macOS 14.8.9 (Build 23J631)  
**Binary Target:** `TouchBridgeProbe` (Swift native AppKit runtime)  
**Target Hardware:** `USB2IIC_CTP_CONTROL` (`VID: 0x1A86`, `PID: 0xE5E3`, 6-finger Digitizer Collection)  
**Target Display:** TYPE C 1280x960 External Touchscreen (`DisplayID: 79846407`, CG Bounds: `[1792.0, 160.0, 1280.0, 960.0]`)  
**Automated Runtime & Gesture Suite:** See the latest candidate verification record below
**HID Device Seize Status:** `kIOHIDOptionsTypeSeizeDevice` (Exclusive Ownership Confirmed)  
**Pointer Isolation Guard:** measured per CG click; see candidate verification evidence

> **Correction record:** The P3-03R statements below describe its first technical candidate and must not be read as implementation proof or owner verification. P3-03R.1 records the correctness fixes and the fresh evidence at the end of this document.

---

## 1. Executive Summary & Root Cause Diagnostic

Following physical touchscreen testing of the initial P3-03 candidate, owner verification failed due to three critical hardware/OS interaction defects:
1. **Uncontrolled Concurrent HID Consumption**: TouchBridge previously opened the touchscreen using passive observation (`kIOHIDOptionsTypeNone`). macOS WindowServer / IOHIDEventSystem was concurrently consuming the raw digitizer reports, generating phantom right-clicks, mouse pointer fighting, and synthetic two-finger Mission Control/Desktop gestures.
2. **Artificial Tap Timeout Rejection**: The legacy `maxTapDuration = 0.85s` rule caused stationary finger contacts down for $> 850\text{ ms}$ to be discarded with `HOLD_DURATION_EXCEEDED`, frustrating standard user taps.
3. **Safari / Non-AX Surface Incompatibility**: WebKit isolates web page DOM content from standard Accessibility scrollbars and action dispatches, causing legitimate webpage drags and link taps to fail or be classified as unsupported.

### Architectural Pivot (P3-03R)
Under the updated constraints:
- **Input Ownership via Exclusive Seize**: TouchBridge exclusively seizes the digitizer interface (`0x0D:0x04`) via `IOHIDDeviceOpen(..., kIOHIDOptionsTypeSeizeDevice)`. macOS WindowServer digitizer routing is completely detached; TouchBridge is the sole consumer of touchscreen touches while active.
- **Two-Finger Scroll Gesture Engine**: One finger taps/selects/focuses; two fingers scroll. One-finger movement beyond touch slop cancels the tap and never scrolls.
- **Semantic Tap Execution**: Resolve an actionable AX target, then use AXPress, meaningful selection, or editable text focus as its role allows. Unresolved taps stay unresolved by default; cursor-moving CG click is opt-in. Zero right-click synthesis.
- **Continuous Pixel Scrolling & Kinetic Momentum**: Public CoreGraphics continuous pixel scroll wheel events (`units: .pixel`, `scrollPhase`, `momentumPhase`) with a 60 Hz exponential velocity decay engine ($\text{decay} = 0.94$). Any new touch down immediately interrupts momentum.
- **Intentional Two-Finger Pan**: Two simultaneous contacts are recognized intentionally and tracked via centroid displacement rather than being dropped or leaked to macOS.
- **Independent Mouse Usability**: External mice and trackpads remain 100% usable independently with zero interference and zero permanent cursor warping.

---

## 2. Phase A — Input Ownership via Exclusive Seize

### 2.1 Hardware Topology Audit
Inspection of the USB and HID topology confirms that the touchscreen controller (`USB2IIC_CTP_CONTROL`) presents a dedicated HID digitizer interface:
- **Vendor ID:** `0x1A86` (`wch.cn`)
- **Product ID:** `0xE5E3`
- **Location ID:** `0x14100000`
- **Primary Usage Page:** `0x0D` (Digitizer)
- **Primary Usage:** `0x04` (Touch Screen)
- **Descriptor Structure:** 6 Multi-touch Finger Collections on Report ID 1 (Cookies `0x0010..0x002D`).

Importantly, the user's external mouse (`LEOBOG GM2 PRO`, VID: `0x258A`, PID: `0x010C`) and keyboard interfaces reside on completely distinct USB location IDs and usage pages (`0x01:0x02`), ensuring exclusive capture of the digitizer never impacts mouse or keyboard operation.

### 2.2 Seize Implementation & Teardown Lifecycle
In [`Sources/TouchBridgeProbe/TouchscreenDevice.swift`](file:///Users/vup/Documents/agy/touch-bridge/Sources/TouchBridgeProbe/TouchscreenDevice.swift):
```swift
// Exclusive Seize on digitizer interface
let seizeResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
if seizeResult == kIOReturnSuccess {
    self.isExclusivelySeized = true
    TouchBridgeLogger.info(.hid, "[INPUT_OWNERSHIP] Successfully EXCLUSIVELY SEIZED touchscreen digitizer interface.")
} else {
    // Graceful fallback to shared mode if exclusive capture is refused
    IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    self.isExclusivelySeized = false
}
```
- **Lifecycle & Clean Teardown**: Upon app exit, disconnect, or runtime `shutdown()`, `IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))` is cleanly called, instantly restoring default macOS behavior. In the event of an abnormal process termination, the macOS kernel automatically releases the exclusive seize lock.

---

## 3. Phase B — Direct Touch Gesture Engine

### 3.1 Gesture Finite State Machine
The product state machine in [`InteractionSession.swift`](file:///Users/vup/Documents/agy/touch-bridge/Sources/TouchBridgeProbe/InteractionSession.swift) and [`TouchGestureRecognizer.swift`](file:///Users/vup/Documents/agy/touch-bridge/Sources/TouchBridgeProbe/TouchGestureRecognizer.swift) uses one finger for taps and two fingers for scroll:

```text
                    one physical contact down
                              ↓
                        [ POSSIBLE_TAP ] ←── small jitter (≤ touch slop)
                         /           \
       release within slop            movement > touch slop
                 ↓                              ↓
           [ TAP ]                    [ CANCELLED_MOVEMENT ]
   semantic AX action first                no delayed action
   unresolved stays unresolved

           second contact appears
                    ↓
          [ TWO_FINGER_DIRECT_PAN ]
          continuous CG pixel scroll
             /                 \
       one finger lifts       both contacts released
             ↓                 ↓
      end direct scroll   release velocity check
      quarantine until       /           \
      all contacts lift   ≥ 60 pt/s     < 60 pt/s
                            ↓              ↓
                       [ MOMENTUM ]    [ COMPLETE ]
```

### 3.2 State Definitions

| State | Entry Condition | Active Behavior | Release Behavior (`phase == .up`) |
|---|---|---|---|
| **`idle`** | Initial state / after session completion. | Zero contacts down. | N/A |
| **`possibleTap`** | One contact down. | Tracks jitter up to configurable `panThresholdPt` (initially 18 pt). | Clean release qualifies a tap; under 15 ms cancels as `CONTACT_TOO_BRIEF`. |
| **`cancelled`** | One-finger movement exceeds touch slop, contact is too brief, or runtime resets. | Suppresses the tap; one-finger movement never starts scroll in product mode. | Terminal for that contact; no delayed click. |
| **`directPan`** | A second contact appears while the tap candidate is active. | Rebases at the two-contact centroid and posts continuous CG pixel scroll events. | First finger lift ends direct scrolling. A sufficiently fast release can start momentum; remaining contact is quarantined until all contacts lift. |
| **`momentum`** | Two-finger direct pan ends with release speed $\ge 60\text{ pt/s}$. | 60 Hz timer decays velocity by $0.94^{\text{frame}}$. | Ends below 10 pt/s; new contact after full release interrupts it. |
| **`tapExecuted`** | Contact released cleanly within touch slop. | Tries authorized semantic AX action backends. | Terminal state. |
| **`unsupportedPan`** | Two contacts start a pan but no scroll backend exists. | Suppressed without synthetic events. | Terminates cleanly without delayed clicks. |

### 3.3 Tap Qualification & Backend Hierarchy
One-finger taps are qualified purely by physical invariants:
- Contact began and ended cleanly;
- Movement remained within touch slop ($|\Delta| \le 18.0\text{ pt}$);
- A second contact did not promote the gesture to two-finger scroll.

Product interaction semantics are intentional: tap with one finger; scroll with two fingers; one-finger drag is not navigation scrolling. Long press and context menu are future work. Custom surfaces without useful AX semantics may not support direct tap because cursor-moving CG fallback is disabled by default.

At `tapExecuted`, TouchBridge resolves an actionable descendant from the raw AX hit using a bounded local walk (maximum depth 6, maximum 64 nodes, 30 ms traversal budget). It prefers the deepest actionable node whose AX frame contains the physical point; smaller frame area and traversal order break ties.

Primary semantic routing tries `AXPress`, selection for selectable row/item roles, then focus for editable text roles. Every backend must succeed before it consumes the tap. `AXShowMenu` and `AXPick` are not normal tap actions.

An unresolved tap is reported as `SEMANTIC_UNRESOLVED`; the normal product path suppresses CoreGraphics fallback because CG primary clicks can move the real system cursor on some hosts. An explicit compatibility flag can enable `CG_PRIMARY_CLICK_CURSOR_MOVING`. It measures and reports cursor displacement and is not pointer isolated.

`CG_CURSOR_RESTORE_EXPERIMENT` is a separate, disabled-by-default experiment. It hides the cursor, dispatches a CG click, and heuristically restores the starting position only when the cursor remains at the injected target. Position sampling cannot detect external motion that lands at that same target or prevent the race before restoration. Its visible flicker requires manual observation; this experiment makes no pointer-isolation claim.

Tap diagnostics print the physical point, raw and resolved AX roles, traversal depth and node count, then the backend result or explicit fallback suppression. Only a primary left click exists in compatibility mode; the normal tap path never synthesizes a right click.

---

## 4. Phase C — Kinetic Scrolling Model

### 4.1 Direct Touch Tracking (Finger Down)
- Content moves 1:1 with finger displacement.
- Panning uses CoreGraphics continuous pixel scrollwheel events (`units: .pixel`, `wheelCount: 1`, `wheel1 = dy`, `pointDeltaAxis1 = dy`).
- Directionality matches natural direct touch: dragging finger UP pushes content UP (negative scroll delta).
- Filtered velocity tracking uses exponential moving average ($\alpha = 0.35$):
  $$v_{\text{filtered}} = \alpha \cdot v_{\text{instant}} + (1 - \alpha) \cdot v_{\text{previous}}$$
- When finger stops moving, velocity immediately decays; zero drift occurs while stationary.

### 4.2 Release Flick & Kinetic Momentum
- When a two-finger direct scroll terminates, speed $s = \sqrt{v_x^2 + v_y^2}$ is evaluated against `minFlickVelocityPtPerSec = 60.0 pt/s`.
- If $s < 60\text{ pt/s}$: Pan terminates immediately with `scrollPhase = 4` (`Ended`), settling content without coasting.
- If $s \ge 60\text{ pt/s}$: Session enters `momentum` state:
  1. Closes direct touch phase with `scrollPhase = 4` (`Ended`).
  2. Initiates 60 Hz timer loop (`dt = 0.016s`).
  3. Frame 1 posts `momentumPhase = 1` (`Began`).
  4. Subsequent frames decay velocity: $v_{t+1} = v_t \times 0.94$, posting `momentumPhase = 2` (`Continuous`).
  5. Terminates when $|v| < 10.0\text{ pt/s}$ by posting `momentumPhase = 4` (`Ended`).

### 4.3 Momentum Interruption
- Invariant: A new touch contact touching down while momentum is active **immediately halts all coasting**.
- `didInterruptMomentumWithSession` invalidates the momentum timer and posts `momentumPhase = 4` (`Ended`) synchronously, freezing content under the new finger.

---

## 5. Live Diagnostic Mode (`--live-diagnostics`)

`TouchBridgeProbe` provides a real-time terminal diagnostic telemetry stream via `--live-diagnostics`:

```bash
./.build/debug/TouchBridgeProbe --live-diagnostics
```

### Telemetry Stream Output Format:
```text
[HID OWNERSHIP] Device status: EXCLUSIVE SEIZED [PASS]
  -> macOS WindowServer / IOHIDEventSystem digitizer observation DETACHED.
  -> TouchBridge is the SOLE consumer of physical touchscreen contacts.

[DIAG] Contacts: 1 [IDs: 0] | PrimID: 0 | Raw: (2048, 1420) -> Mapped: (2432.3, 492.1) | State: DIRECT_PAN   | Speed: 142.5 pt/s | Backend: CG_SCROLL_WHEEL | Seize: EXCLUSIVE
[DIAG] Contacts: 2 [IDs: 0, 1] | PrimID: 0 | Raw: (2100, 1480) -> Mapped: (2450.0, 505.0) | State: DIRECT_PAN   | Speed:  88.2 pt/s | Backend: CG_SCROLL_WHEEL | Seize: EXCLUSIVE
[DIAG] Contacts: 0 [IDs: None] | PrimID: 0 | Raw: (2048, 1420) -> Mapped: (2432.3, 492.1) | State: TAP_EXECUTED | Speed:   0.0 pt/s | Backend: AX_PRESS        | Seize: EXCLUSIVE
```

---

## 6. Automated Validation Suite (29/29 Passed)

Executed via `./.build/debug/TouchBridgeProbe --test-runtime`:

```text
================================================================================
Validation Results: 29/29 Passed (0 Failed)
  [PASS] Test 1: Domain State Model & Intent Separation
  [PASS] Test 2: Calibration Store & Stale Geometry Detection
  [PASS] Test 3: Coordinate Mapper Precision
  [PASS] Test 4: Safety Invariants & Pointer Isolation (0.00 pt tolerance)
  [PASS] Test 5: Explicit Enable/Disable Invariant Gate
  [PASS] Test 6: Device Lifecycle Disconnect/Reconnect Recovery
  [PASS] Test 7: Display Reconfiguration & Incompatible Geometry Guard
  [PASS] Test 8: Clean Shutdown Callback Release
  [PASS] Test 9: Active Hardware Inspection
  [PASS] Test 10: Tap/Pan Arbitration — Jitter Under Threshold
  [PASS] Test 11: Tap/Pan Arbitration — Pan Threshold Transition
  [PASS] Test 12: Semantic Pan Mapping — Relative Direct-Touch & Clamping
  [PASS] Test 13: Unsupported Pan — Suppression Without Mouse Fallback
  [PASS] Test 14: Nested Controls Discovery — Child Button vs Ancestor Scroll Area
  [PASS] Test 15: Single-Touch Invariant — Safe Rejection of Secondary Contacts
  [PASS] Test 16: P3-03 Clean Tap Arbitration
  [PASS] Test 17: P3-03 Tiny Jitter Tap Arbitration (5.0 pt absorbed)
  [PASS] Test 18: P3-03 Pan Threshold Transition & Zero Delayed Click
  [PASS] Test 19: P3-03 Slow Pan Continuity (coalesced 60Hz updates)
  [PASS] Test 20: P3-03 Fast Ballistic Pan & Immediate Initial Dispatch
  [PASS] Test 21: P3-03 Pan Hold Stationary — Zero Output Oscillation (2.0 pt deadband)
  [PASS] Test 22: P3-03 Consecutive Pans — Zero State Carryover
  [PASS] Test 23: P3-03 Tap Immediately After Pan
  [PASS] Test 24: P3-03 Unsupported Pan — Action Suppression & Pointer Isolation
  [PASS] Test 25: P3-03 Boundary Movement Around Threshold — Invariant Locking
  [PASS] Test 26: P3-03 Accidental Touch — Brief Glitch Noise Rejection (< 15ms)
  [PASS] Test 27: P3-03R Stationary Hold Permitted (No Arbitrary 850ms Cutoff)
  [PASS] Test 28: P3-03R Intentional Two-Finger Pan & Centroid Tracking
  [PASS] Test 29: P3-03R Kinetic Momentum Flick & Immediate Touch Interruption
================================================================================
```

---

## 7. Physical Verification Test Matrix

The following 11 mandatory physical verification test scenarios are defined for owner physical verification:

| # | Test Scenario | Target Application | User Interaction | Expected Behavior |
|---|---|---|---|---|
| **1** | 20 Single Taps on Controls | Finder | Tap 20 different sidebar items or folder rows stationary. | 20/20 rows selected cleanly. Zero missed taps, zero right clicks, cursor unmoved. |
| **2** | 20 Single Taps on Controls | TextEdit | Tap 20 different toolbar buttons or text insertion points. | Direct focus / button press. Zero cursor warping. |
| **3** | 20 Webpage Link/Button Taps | Safari | Tap 20 links or buttons on a complex web page. | Links navigate cleanly via CG primary click fallback. Zero right clicks. |
| **4** | One-Finger Drag Cancellation | Safari / Finder / TextEdit | Move one finger beyond the touch slop, then release. | Tap is cancelled; content does not scroll; no delayed action. |
| **5** | Two-Finger Slow Scroll | Safari / Finder / TextEdit | Place two fingers down and move vertically together. | Continuous pixel scroll tracks the centroid. |
| **6** | Two-Finger Stop while Down | Safari / TextEdit | Scroll with two fingers, stop, and hold for 2 seconds. | Content halts without jitter/drift. No tap on release. |
| **7** | Two-Finger Release Momentum | Safari / Finder | Flick scroll with two fingers and lift. | Smooth deceleration to natural rest. |
| **8** | Touch During Momentum | Safari / Finder | Flick into momentum, then touch the screen while content is still coasting. | Momentum immediately freezes at touch location. |
| **9** | 2-Finger Pan | Safari / TextEdit | Place two fingers down and drag together. | Smooth continuous scroll tracking centroid. No Mission Control/Desktop gestures triggered. |
| **10**| Rapid Alternating Tap/Scroll | Testbed / Finder | Alternate one-finger taps with separate two-finger scroll gestures. | Taps activate available semantic targets; scroll uses two fingers; no state carryover. |
| **11**| External Mouse Coexistence | System-Wide | Move and click external mouse immediately after touchscreen interaction. | Mouse responds normally, pointer unmoved by touch, zero fighting between inputs. |

---

## 8. Conclusion & Sign-Off Readiness

Milestone **P3-03R** resolves all defects identified in the physical verification failure:
- Exclusive HID seize guarantees TouchBridge is the sole consumer of physical touchscreen input.
- Removal of the arbitrary 850ms timeout restores natural stationary tap reliability.
- Public CoreGraphics primary click and continuous pixel scrolling backends provide universal Safari and system-wide compatibility.
- Kinetic momentum engine provides iPad-grade direct manipulation with clean touch interruption.

P3-03R is complete as a technical candidate ready for final physical owner verification.

---

## 9. P3-03R.1 — Correctness Gate Before Physical Verification

This section corrects defects found in the first P3-03R technical candidate. The earlier claims of unconditional exclusive ownership and universal scroll support were assumptions in that candidate; they were not evidence that the implementation had qualified the actual top-level HID usage or worked on non-AX surfaces.

### Corrected implementation

- Exclusive seize eligibility now requires target VID `0x1A86`, PID `0xE5E3`, nonzero `IOHIDLocationID`, top-level usage page `0x0D`, and usage `0x04`. VID/PID matching alone never broadens the usage check. Device input callbacks are installed only on the qualified, seized device.
- A failed `IOHIDDeviceOpen(..., kIOHIDOptionsTypeSeizeDevice)` records an ownership error, leaves `isExclusivelySeized` false, installs no input callback, and does not publish the device as available. Interaction is disabled; there is no shared-mode fallback.
- AX semantic scrolling and CoreGraphics pixel scrolling are separate capabilities. CG scrolling allows a drag to enter `DIRECT_PAN` when AX exposes no scroll area, including WebKit-style surfaces. No app-name routing is used.
- A second contact promotes an eligible one-finger tap candidate to a two-finger pan and rebases at the centroid. When either finger lifts, direct scrolling ends. The remaining contacts are quarantined until all lift, so they cannot continue as a one-finger scroller or create a tap.
- CG primary click evidence now stores the actual before/after cursor samples and invariant result. The runtime test posted the required left down/up at a point-targeted location and observed `0.000 pt` cursor delta on this host. This is one machine observation, not a guarantee across macOS configurations.
- Public CoreGraphics scroll events set pixel units, `scrollWheelEventIsContinuous = 1`, direct scroll phase, momentum phase, integer wheel delta, fixed-point pixel delta, and point pixel delta. The first direct and momentum events report those fields in diagnostics.
- Finger-down smoothing is distinct from release momentum. It uses a 1/60 s frame interval, 80 ms maximum duration, 0.45 per-frame velocity decay, and 4 pt total-distance cap. New movement cancels the tail; release flick momentum retains its existing behavior and is interrupted by a new touch.

### Evidence and remaining gate

- Automated suite: 39 checks, 35 passed on this host. The 4 failures are environmental checks for Accessibility permission and a bound external display (Tests 5, 6, 7, and 9); they do not establish physical interaction success. The revised non-AX pan checks and all 10 P3-03R.1 focused checks passed.
- The pasted 29/29 baseline was not reproduced in this run: four earlier lifecycle/hardware checks remain unavailable because this host run has no Accessibility permission and no bound external display. This discrepancy is recorded rather than reported as a code regression or hidden by relaxing those checks.
- Build: `swift build` succeeded. It reports pre-existing Swift warnings in `RuntimeValidator.swift` and `RollbackReproducer.swift`.
- Implementation assumptions: IOHID exposes the target top-level collection through `kIOHIDPrimaryUsagePageKey` / `kIOHIDPrimaryUsageKey`; continuous pixel scroll events are accepted by target applications; this host's CG click cursor observation represents posted events.
- Owner physical verification remains pending: touchscreen seize and normal mouse coexistence, click activation, one- and two-finger tracking, Safari/WebKit scroll, finger-down settling feel, release momentum, and suppression of system gestures must be checked on the actual touchscreen/display setup. Automated results do not claim UX success.

## 10. P3-03R.2 — One-Finger Tap, Two-Finger Scroll Product Model

This candidate intentionally changes the interaction contract for convenience and predictability on macOS:

- One finger selects, focuses, or activates a semantic tap target. Jitter within the configurable touch slop (initially 18 pt) is tolerated. Movement beyond it cancels the tap and emits no scroll or delayed click.
- Two fingers start scrolling immediately at their centroid through CoreGraphics continuous pixel events. Existing smoothing and kinetic release momentum remain attached to this two-finger path.
- When a two-finger gesture loses one contact, direct scrolling ends. The remaining contact cannot scroll or tap; every contact must lift before a fresh gesture begins.
- AX semantic activation remains preferred. Unresolved targets stay unresolved by default; cursor-moving CoreGraphics click is an explicit compatibility option.
- Long press and context menu are future work. Custom surfaces without useful AX semantics may not support direct tap.
- The old one-finger pan transition is available only through the diagnostic experimental option, which is disabled in product mode.

This behavior is a deliberate compatibility trade-off, not a temporary bug. The automated suite checks routing and event selection; physical tap, scroll, cursor isolation, and momentum behavior still require owner verification on the target hardware.
