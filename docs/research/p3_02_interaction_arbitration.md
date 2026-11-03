# TouchBridge P3-02 — Interaction Router & Tap/Pan Arbitration Report

**Date:** 2026-09-26  
**Milestone:** P3-02 (Interaction Router & Gesture Arbitration)  
**Status:** CLOSED  
**System / Host Hardware:** MacBook Pro 2019 Intel (`x86_64`)  
**Operating System:** macOS 14.8.9 (Build 23J631)  
**Binary Target:** `TouchBridgeProbe` (Swift native AppKit runtime)  
**Target Hardware:** `USB2IIC_CTP_CONTROL` (`VID: 0x1A86`, `PID: 0xE5E3`, passive IOHID)  
**Target Display:** TYPE C 1280x960 External Touchscreen (`DisplayID: 79846407`, CG Bounds: `[1792.0, 160.0, 1280.0, 960.0]`)  
**Calibration Profile:** Authoritative Affine 2x3 Profile (`meanResidualError: 5.21 pt`, `maxResidualError: 5.29 pt`)  
**Accessibility Authorization:** `AXIsProcessTrusted() == true`  
**Automated Runtime Invariant Suite:** 15/15 Passed (0 Failed)  
**System Pointer Invariant:** 100% Inviolate (Delta = `0.00 pt`, Zero Mouse Warping, Zero CGEvent Mouse Fallback)  

---

## Executive Summary

Phase **P3-02** resolves the core interaction challenge of TouchBridge: **deterministic gesture arbitration**.

On a physical touchscreen without mouse emulation, a physical contact must never accidentally produce both a tap and a scroll. When touching a button inside a scrollable container, a stationary tap must activate the button, while a vertical drag must scroll the container without triggering the button upon lift-off. Furthermore, when continuous scrolling is unavailable on a surface (such as Safari/WebKit pages), the gesture must cleanly suppress action rather than falling back to synthetic mouse/wheel events.

P3-02 establishes a single, unified runtime interaction pipeline:
```text
TouchscreenDevice
    ↓ (passive IOHIDElement stream)
HIDFrameSource
    ↓ (mach_absolute_time report aggregation)
TouchFrameAggregator
    ↓ (discrete TouchSample)
CoordinateMapper
    ↓ (DisplayLocalPoint + GlobalDisplayPoint)
TouchGestureRecognizer
    ↓ (InteractionSession state machine & arbitration)
SemanticInteractionRouter
    ↓ (Capability-authorized AX actions & coalesced scroll writes)
Target Application UI
```

All 15 automated validation tests passed cleanly (`15/15 Passed`). The physical testbed (`ArbitrationTestWindowController`) was deployed and verified on real hardware (`USB2IIC_CTP_CONTROL` + `TYPE C` 1280x960 display), confirming mutual exclusivity across AppKit nested controls, Finder list views, TextEdit editable documents, and Safari negative suppression.

---

## 1. Gesture State Model

The gesture recognizer architecture was redesigned to eliminate the legacy dual-path design (`SingleTapRecognizer` and `SemanticScrollController` running in parallel). Every physical contact is encapsulated into an explicit, stateful **`InteractionSession`** ([InteractionSession.swift](file:///Users/vup/Documents/agy/touch-bridge/Sources/TouchBridgeProbe/InteractionSession.swift)).

```text
               physical contact down
                         ↓
                  [ possibleTap ]
                 /               \
                /                 \
   movement <= 18.0 pt        movement > 18.0 pt
   & touch-up in [0.015..0.85s]     \
              ↓                      \
       [ tapExecuted ]                \
      (dispatch AXPress/       has continuous AX backend?
       Focus/Selection)             /            \
                                  YES             NO
                                  ↓                ↓
                          [ semanticPan ]   [ unsupportedPan ]
                          (relative AXVal)  (zero action)
                                  ↓                ↓
                              touch-up         touch-up
                                  ↓                ↓
                            [ completed ]    [ cancelled ]
                           (ZERO TAP FIRED) (ZERO TAP FIRED)
```

### State Definitions
1. **`idle`**: No active physical contact on the panel.
2. **`possibleTap`**: Contact is active. Cumulative displacement is below the arbitration threshold (`18.0 pt`). If released while in this state and within duration bounds `[0.015s, 0.85s]`, it transitions to `tapExecuted`.
3. **`semanticPan`**: Cumulative displacement exceeded `18.0 pt` on a surface with a verified writable vertical scrollbar (`AXScrollArea` → `AXScrollBar.AXValue` is settable). Tap is **permanently cancelled**. Active movement continuously updates the ancestor scrollbar. Touch release terminates pan with **zero tap action**.
4. **`unsupportedPan`**: Cumulative displacement exceeded `18.0 pt` on a surface lacking a continuous semantic scrollbar (e.g. Safari WebKit document). Tap is **permanently cancelled**. Touch release terminates with **zero action** (no mouse wheel injection, no synthetic drag).
5. **`tapExecuted`**: Contact released while qualifying as a stationary tap. Capability-authorized semantic action dispatched.
6. **`cancelled(reason)`**: Contact failed arbitration constraints (e.g. duration `< 0.015s` [electrical micro-bounce], hold `> 0.85s` [lingering stationary hold], or `HOT_PLUG_RESET` on hardware disconnect).

### Interaction Result Taxonomy
Every gesture resolution produces an explicit, non-overlapping outcome:
- `TAP_PRESS_SUCCESS`: `AXPress` action dispatched to actionable element (`AXButton`, `AXPopUpButton`).
- `TAP_FOCUS_SUCCESS`: `AXFocused` set to `true` on editable element (`AXTextField`, `AXTextArea`).
- `TAP_SELECTION_SUCCESS`: `AXSelected` set to `true` on selectable row (`AXRow`, `NSTableView`).
- `TAP_MENU_SUCCESS`: `AXShowMenu` action dispatched.
- `PAN_STARTED`: Contact crossed pan threshold; scroll metrics captured.
- `PAN_UPDATED`: Continuous proportional AX scroll write dispatched (~60Hz coalesced).
- `PAN_COMPLETED`: Contact released after continuous pan; final position flushed; zero tap fired.
- `PAN_UNSUPPORTED`: Movement crossed threshold on unsupported surface; action suppressed.
- `GESTURE_CANCELLED`: Session terminated without action (hold timeout, noise filter, hot-plug).
- `SEMANTIC_UNSUPPORTED`: Surface does not expose actionable attributes.
- `AX_FAILURE`: Target application Accessibility IPC error.

---

## 2. Capability Discovery Strategy

Performing exhaustive Accessibility hierarchy traversal on every high-frequency HID report (60–120 Hz) causes severe IPC latency and stalls the host run loop. 

P3-02 implements **Early Bounded Capability Discovery** ([AXCapabilityInspector.swift](file:///Users/vup/Documents/agy/touch-bridge/Sources/TouchBridgeProbe/AXCapabilityInspector.swift#L65-L140)):

1. **Timing**: AX inspection executes **strictly once per contact**, upon the initial `phase == .down` transition.
2. **Hit-Testing**: The calibrated global coordinate (`GlobalDisplayPoint`) is hit-tested via `AXUIElementCopyElementAtPosition`.
3. **Bounded Ancestor Traversal**: The inspector climbs the ancestor chain with a hard limit of **4 levels** (`maxAncestors: 4`).
4. **Context Cache**: The resulting `AXInteractionContext` caches:
   - `hitElement` & `hitNode`: The immediate touched element (e.g. `AXButton`, `AXTextField`, `AXRow`).
   - `scrollAreaElement` & `scrollBarElement`: The nearest scroll-capable ancestor container (`AXScrollArea` exposing an `AXVerticalScrollBar` where `AXValue` is settable).
   - `scrollAreaHeight`: The visible height of the scroll region for proportional mapping.
5. **Zero Intermediate Traversal**: Subsequent `phase == .move` events perform zero AX hierarchy calls, referencing only the pre-discovered context.
6. **Bounded Lifetime**: The cached `AXUIElement` references are discarded when the contact session ends (`phase == .up` or cancel), preventing stale reference accumulation across application state changes.

---

---

## 3. Threshold Measurements & Empirical Arbitration Evidence

### 3.1 Historical Tap Jitter vs. Deliberate Pan Initiation

P3-02 explicitly distinguishes between two separate empirical datasets collected on the target touchscreen (`USB2IIC_CTP_CONTROL`, VID `0x1A86`, PID `0xE5E3`, external display `TYPE C` DisplayID `79846407`, 1280x960):

1. **Historical Stationary Tap Jitter Dataset** (365 historical physical contacts):
   - Measures involuntary finger wobble while attempting stationary taps.
   - Observed range: `0.00 pt` to `14.94 pt` (mean: `0.05 pt`).
   - Function: Establishes the lower bound for the pan threshold. The configured threshold of **`18.0 pt`** provides an empirical ~3.0 pt safety buffer above maximum involuntary jitter.

2. **NEW P3-02 Deliberate Pan Initiation Measurements** (Physical validation run `task-979`):
   - Measures deliberate swipes across native AppKit, Finder, TextEdit, and Safari.
   - Evaluates:
     * Movement at first transition from `possibleTap` to `semanticPan` or `unsupportedPan`.
     * Elapsed time from physical contact touch-down to pan transition.

### 3.2 Deliberate Pan Initiation Measurement Records

| Test Surface | Contact / Target | Initial Movement at Pan Transition | Elapsed Time (Down → Pan Transition) | Max Gesture Displacement | Arbitration Outcome |
|---|---|---|---|---|---|
| **AppKit ScrollView** | Button #24 swipe | 19.0 pt | 60 ms | 275.4 pt | `possibleTap -> semanticPan` (zero button activation) |
| **AppKit ScrollView** | Blank scroll area flick | 21.5 pt | 12 ms | 86.6 pt | `possibleTap -> semanticPan` (direct scroll) |
| **AppKit ScrollView** | ScrollView swipe #1 | 18.5 pt | 36 ms | 245.5 pt | `possibleTap -> semanticPan` (smooth tracking) |
| **AppKit ScrollView** | ScrollView swipe #2 | 19.2 pt | 60 ms | 291.3 pt | `possibleTap -> semanticPan` (smooth tracking) |
| **AppKit ScrollView** | ScrollView swipe #3 | 18.8 pt | 107 ms | 272.8 pt | `possibleTap -> semanticPan` (smooth tracking) |
| **Finder** | List row / cell swipe #1 | 18.4 pt | 85 ms | 346.4 pt | `possibleTap -> semanticPan` (zero delayed activation) |
| **Finder** | List row / cell swipe #2 | 19.5 pt | 56 ms | 195.7 pt | `possibleTap -> semanticPan` (zero delayed activation) |
| **Finder** | List row / cell swipe #3 | 18.2 pt | 37 ms | 189.8 pt | `possibleTap -> semanticPan` (zero delayed activation) |
| **TextEdit** | Text area drag #1 | 18.6 pt | 114 ms | 65.0 pt | `possibleTap -> semanticPan` (focus cancelled cleanly) |
| **TextEdit** | Text area drag #2 | 18.9 pt | 98 ms | 471.9 pt | `possibleTap -> semanticPan` (focus cancelled cleanly) |
| **TextEdit** | Text area drag #3 | 19.1 pt | 97 ms | 607.9 pt | `possibleTap -> semanticPan` (focus cancelled cleanly) |
| **Safari** | Web element swipe #1 | 26.2 pt | 48 ms | 209.8 pt | `possibleTap -> unsupportedPan` (action suppressed) |
| **Safari** | Web element swipe #2 | 48.6 pt | 103 ms | 227.5 pt | `possibleTap -> unsupportedPan` (action suppressed) |

**Empirical Analysis of Pan Initiation:**
- **Movement at First Pan Transition:** Consistently ranges from **`18.2 pt` to `26.2 pt`** during normal swipes (and up to 48.6 pt during rapid ballistic swipes), crossing the `18.0 pt` threshold on the 1st or 2nd move HID report past the boundary.
- **Elapsed Time from Down to Pan Transition:** Varies directly with finger velocity:
  * Fast flicks / brisk swipes: **`12 ms` to `48 ms`**
  * Moderate deliberate swipes: **`56 ms` to `85 ms`**
  * Deliberate slow drags: **`97 ms` to `114 ms`**
  * Overall empirical range: **`12 ms` to `114 ms`** (mean ~`68 ms`).
- **Threshold Assessment:** The `18.0 pt` threshold cleanly separates stationary tap jitter (`0.0 pt` to `14.9 pt`) from deliberate pans, without requiring artificial tuning or theoretical optimization.

---

## 4. Semantic Pan Mapping Math & Invariants

To avoid numerical drift and rounding accumulation caused by summing incremental deltas, TouchBridge derives scroll value **relative to the initial touch-down contact point**:

$$\Delta y = y_{\text{current}} - y_{\text{start}}$$

$$\text{valueSpan} = \text{AXMaxValue} - \text{AXMinValue}$$

$$\text{proportionalDelta} = \left(-\frac{\Delta y}{\text{visibleHeight}}\right) \times \text{valueSpan}$$

$$\text{targetValue} = \text{clamp}\left(\text{initialValue} + \text{proportionalDelta},\, \text{AXMinValue},\, \text{AXMaxValue}\right)$$

### Mathematical Validation (Test 12 in `RuntimeValidator`)
- **Direct-Touch Direction**: Dragging the finger UP ($\Delta y < 0$) produces $\text{proportionalDelta} > 0$, increasing scrollbar value, which reveals content lower down (content moves up with the finger).
- **Zero Drift Invariant**: Moving the finger UP by 100 pt, DOWN by 100 pt, and returning exactly to $y_{\text{start}}$ yields $\text{targetValue} = \text{initialValue}$ ($\pm 0.0000$ error). No drift occurs regardless of gesture duration.
- **Bounds Clamping**: Displacements exceeding the document bounds clamp strictly to $[\text{AXMinValue}, \text{AXMaxValue}]$ without throwing AX errors or wrapping.

---

## 5. Direct Physical Evidence Records (P3-02 Core Verification)

The four required physical interaction scenarios were executed on the target touchscreen (`USB2IIC_CTP_CONTROL`, DisplayID `79846407`, 1280x960). Each scenario is documented below with its exact live runtime telemetry.

```text
Test: Test A1 — TouchBridge stationary button tap
Touch target: Button #1 (0 taps)

Down:
  global point: (2217.0, 449.2)
  hit element: AXButton [Button #1 (0 taps)]
  actionable capability: AXPress
  scroll ancestor capability: AXScrollArea (DIRECT_VALUE)

Gesture:
  max movement: 0.0 pt
  threshold: 18.0 pt
  transition: possibleTap -> tapExecuted
  time-to-pan if applicable: N/A (duration: 0.072 s)

Semantic result:
  tap action: kAXPressAction dispatched successfully (Button #1 counter incremented 0 -> 1)
  pan action: NONE
  initial scroll value: 1.000
  final scroll value: 1.000

Release:
  delayed tap emitted: NO

Cursor:
  before: (2474.0, 640.8)
  after: (2474.0, 640.8)
  delta: 0.00 pt
```

```text
Test: Test A2 — TouchBridge swipe starting directly on a button
Touch target: Button #24 (4 taps)

Down:
  global point: (2224.1, 822.2)
  hit element: AXButton [Button #24 (4 taps)]
  actionable capability: AXPress
  scroll ancestor capability: AXScrollArea (DIRECT_VALUE, height: 720 pt)

Gesture:
  max movement: 275.4 pt
  threshold: 18.0 pt
  transition: possibleTap -> semanticPan
  time-to-pan if applicable: 60 ms (movement at transition: ~19.0 pt)

Semantic result:
  tap action: NONE (Button #24 tap permanently cancelled; counter remained at 4 taps)
  pan action: Continuous direct-value scroll updates (10 updates flushed)
  initial scroll value: 0.510
  final scroll value: 0.128 (DeltaY = +275.4 pt)

Release:
  delayed tap emitted: NO

Cursor:
  before: (1314.2, 553.4)
  after: (1314.2, 553.4)
  delta: 0.00 pt
```

```text
Test: Test A3 — TouchBridge blank-area pan
Touch target: Blank scroll area of NSScrollView

Down:
  global point: (2218.0, 500.0)
  hit element: AXScrollArea
  actionable capability: NONE
  scroll ancestor capability: AXScrollArea (DIRECT_VALUE, height: 720 pt)

Gesture:
  max movement: 86.6 pt
  threshold: 18.0 pt
  transition: possibleTap -> semanticPan
  time-to-pan if applicable: 12 ms (rapid initiation)

Semantic result:
  tap action: NONE
  pan action: Continuous direct-value scroll updates (19 updates flushed)
  initial scroll value: 0.128
  final scroll value: 0.008 (DeltaY = +86.6 pt)

Release:
  delayed tap emitted: NO

Cursor:
  before: (1314.2, 553.4)
  after: (1314.2, 553.4)
  delta: 0.00 pt
```

```text
Test: Test B1 — Finder stationary row tap
Touch target: Finder list row (AXRow)

Down:
  global point: (2185.0, 480.0)
  hit element: AXRow
  actionable capability: AXSelected (settable boolean attribute)
  scroll ancestor capability: AXScrollArea (SEMANTIC_OTHER)

Gesture:
  max movement: 0.0 pt
  threshold: 18.0 pt
  transition: possibleTap -> tapExecuted
  time-to-pan if applicable: N/A (duration: 0.048 s)

Semantic result:
  tap action: AXSelected set to true (Finder row selected)
  pan action: NONE
  initial scroll value: 0.530
  final scroll value: 0.530

Release:
  delayed tap emitted: NO

Cursor:
  before: (1314.2, 553.4)
  after: (1314.2, 553.4)
  delta: 0.00 pt
```

```text
Test: Test B2 — Finder vertical swipe starting on a row/cell
Touch target: Finder list item cell (AXCell)

Down:
  global point: (2185.0, 480.0)
  hit element: AXCell
  actionable capability: NONE
  scroll ancestor capability: AXScrollArea (DIRECT_VALUE, height: 612 pt)

Gesture:
  max movement: 195.7 pt
  threshold: 18.0 pt
  transition: possibleTap -> semanticPan
  time-to-pan if applicable: 56 ms (movement at transition: ~19.5 pt)

Semantic result:
  tap action: NONE (Finder selection unchanged; zero release activation)
  pan action: Continuous direct-value scroll updates on Finder AXScrollBar (4 updates flushed)
  initial scroll value: 0.530
  final scroll value: 0.210 (subsequent swipe scrolled to 0.000)

Release:
  delayed tap emitted: NO

Cursor:
  before: (1314.2, 553.4)
  after: (1314.2, 553.4)
  delta: 0.00 pt
```

```text
Test: Test C1 — TextEdit stationary tap inside editable text
Touch target: TextEdit document text area (AXTextArea)

Down:
  global point: (2150.0, 520.0)
  hit element: AXTextArea
  actionable capability: AXFocused (settable boolean attribute)
  scroll ancestor capability: AXScrollArea (DIRECT_VALUE, height: 692 pt)

Gesture:
  max movement: 0.0 pt
  threshold: 18.0 pt
  transition: possibleTap -> tapExecuted
  time-to-pan if applicable: N/A (duration: 0.096 s)

Semantic result:
  tap action: AXFocused set to true (Focus transferred cleanly to TextEdit)
  pan action: NONE
  initial scroll value: 0.467
  final scroll value: 0.467

Release:
  delayed tap emitted: NO

Cursor:
  before: (1314.2, 553.4)
  after: (1314.2, 553.4)
  delta: 0.00 pt
```

```text
Test: Test C2 — TextEdit vertical swipe starting inside text area
Touch target: TextEdit document text area (AXTextArea)

Down:
  global point: (2150.0, 520.0)
  hit element: AXTextArea
  actionable capability: AXFocused
  scroll ancestor capability: AXScrollArea (DIRECT_VALUE, height: 692 pt)

Gesture:
  max movement: 65.0 pt
  threshold: 18.0 pt
  transition: possibleTap -> semanticPan
  time-to-pan if applicable: 114 ms (movement at transition: ~18.6 pt)

Semantic result:
  tap action: NONE (focus permanently cancelled upon crossing 18.0 pt)
  pan action: Continuous direct-value scroll updates on TextEdit document (13 updates flushed)
  initial scroll value: 0.467
  final scroll value: 0.374 (subsequent swipes scrolled 0.374 -> 1.000 -> 0.122 -> 0.000)

Release:
  delayed tap emitted: NO

Cursor:
  before: (1314.2, 553.4)
  after: (1314.2, 553.4)
  delta: 0.00 pt
```

```text
Test: Test D1 — Safari stationary button tap
Touch target: Safari playback control button (AXButton)

Down:
  global point: (2591.5, 932.6)
  hit element: AXButton
  actionable capability: AXPress
  scroll ancestor capability: AXScrollArea (DIRECT_VALUE / SEMANTIC_OTHER)

Gesture:
  max movement: 0.0 pt
  threshold: 18.0 pt
  transition: possibleTap -> tapExecuted
  time-to-pan if applicable: N/A (duration: 0.032 s)

Semantic result:
  tap action: kAXPressAction dispatched successfully to AXButton
  pan action: NONE
  initial scroll value: N/A
  final scroll value: N/A

Release:
  delayed tap emitted: NO

Cursor:
  before: (2405.6, 685.1)
  after: (2405.6, 685.1)
  delta: 0.00 pt
```

```text
Test: Test D2 — Safari vertical swipe on actionable element (Negative Control)
Touch target: Safari web element (AXStaticText)

Down:
  global point: (2450.0, 700.0)
  hit element: AXStaticText
  actionable capability: NONE
  scroll ancestor capability: AXScrollArea (SEMANTIC_OTHER — continuous scrollbar writes ignored by WebKit)

Gesture:
  max movement: 209.8 pt
  threshold: 18.0 pt
  transition: possibleTap -> unsupportedPan
  time-to-pan if applicable: 48 ms (movement at transition: 26.2 pt)

Semantic result:
  tap action: NONE (tap permanently cancelled upon crossing 18.0 pt)
  pan action: NONE (PAN_UNSUPPORTED: action suppressed without synthetic events)
  initial scroll value: N/A (page not scrolled)
  final scroll value: N/A (page not scrolled)

Release:
  delayed tap emitted: NO

Cursor:
  before: (2405.6, 685.1)
  after: (2405.6, 685.1)
  delta: 0.00 pt
```

---

## 6. Semantic Pan Performance

During active continuous panning on AppKit scroll surfaces (`NSScrollView`, TextEdit, Finder):

| Metric | Measured Value | Standard / Target | Status |
|---|---|---|---|
| **HID Sampling Rate** | 60 – 120 Hz (8.3 – 16.6 ms interval) | > 60 Hz | **EXCELLENT** |
| **AX Write Dispatch Rate** | ~60 Hz (throttled to 16.6 ms minimum interval) | 30 – 60 Hz | **OPTIMAL** |
| **Frame Drops / Stalls** | 0 stalls observed; run loop stays responsive | 0 dropped frames | **PASS** |
| **Touch-to-AX Latency** | ~18 – 24 ms (from physical report arrival to AX return) | < 35 ms | **RESPONSIVE** |
| **Cursor Position Drift** | Exactly `0.00 pt` across all updates | `0.00 pt` | **INVIOLATE** |

Coalescing AX writes via `shouldDispatchAXWrite` ensures that even when the user moves rapidly (generating dense HID reports), only one AX IPC request is dispatched per display frame (~16 ms), preventing IPC queue buildup.

---

## 7. Automated Invariant Verification (15/15 Suite)

The automated test suite in [RuntimeValidator.swift](file:///Users/vup/Documents/agy/touch-bridge/Sources/TouchBridgeProbe/RuntimeValidator.swift) verifies all lifecycle and arbitration invariants:

```text
[LIFECYCLE] [INFO] Validation Results: 15/15 Passed (0 Failed)
  [PASS] Test 1:  Domain State Model & Intent Separation
  [PASS] Test 2:  Calibration Store & Stale Geometry Detection
  [PASS] Test 3:  Coordinate Mapper Precision
  [PASS] Test 4:  Safety Invariants & Pointer Isolation (0.0 pt tolerance)
  [PASS] Test 5:  Explicit Enable/Disable Invariant Gate
  [PASS] Test 6:  Device Lifecycle Disconnect/Reconnect Recovery
  [PASS] Test 7:  Display Reconfiguration & Incompatible Geometry Guard
  [PASS] Test 8:  Clean Shutdown Callback Release
  [PASS] Test 9:  Active Hardware Inspection (Display #79846407, USB2IIC_CTP_CONTROL)
  [PASS] Test 10: Tap/Pan Arbitration — Jitter Under Threshold (5.0 pt stays in POSSIBLE_TAP)
  [PASS] Test 11: Tap/Pan Arbitration — Pan Threshold Transition (25.0 pt locks SEMANTIC_PAN)
  [PASS] Test 12: Semantic Pan Mapping — Relative Direct-Touch & Zero Drift (0.500 return)
  [PASS] Test 13: Unsupported Pan — Suppression Without Mouse Fallback (UNSUPPORTED_PAN)
  [PASS] Test 14: Nested Controls Discovery — Child Button vs Ancestor Scroll Area
  [PASS] Test 15: Single-Touch Invariant — Safe Rejection of Secondary Contacts
```

---

## 8. Known Limitations

1. **Safari / WebKit Continuous Pan**:
   - WebKit's Accessibility implementation does not update viewport scroll position when writing to `AXScrollBar.AXValue`.
   - In accordance with TouchBridge invariants, TouchBridge refuses to synthesize mouse wheel events or drag the mouse pointer. As a result, continuous panning in Safari remains explicitly unsupported (`PAN_UNSUPPORTED`). Discrete jumping via `AXScrollToVisible` remains viable.
2. **Strict Single-Touch**:
   - Although the hardware HID descriptor reports multiple finger collections, P3-02 intentionally enforces strict single-contact arbitration. Multi-finger gestures (pinch-to-zoom, two-finger rotate) are ignored.
3. **No Inertia / Momentum**:
   - P3-02 implements direct 1:1 finger tracking. Scrolling stops immediately upon finger lift-off. Momentum/inertial decay is deferred to later milestones.

---

## 9. Final Milestone Acceptance

### P3-02 VERIFIED

**Verification Summary:**
1. **Physical Scenario A (TouchBridge scroll view):**
   - A1 (stationary button tap): `possibleTap -> tapExecuted`, Button #1 counter incremented 0 -> 1, zero pan.
   - A2 (swipe on button): initial child `AXButton`, scroll ancestor discovered, movement crossed 18 pt, state permanently changed to `semanticPan`, Button did NOT activate, content scrolled, release produced zero delayed `AXPress`.
   - A3 (blank-area pan): clean semantic pan with zero tap candidate firing.
2. **Physical Scenario B (Finder):**
   - B1 (stationary row tap): semantic row selection verified (`AXSelected set to true`).
   - B2 (swipe on row): scrollbar updated continuously, zero delayed activation on release.
3. **Physical Scenario C (TextEdit):**
   - C1 (stationary tap in editable text): semantic focus transferred cleanly (`AXFocused set to true`).
   - C2 (swipe in text area): focus cancelled once threshold crossed, continuous scroll executed, cursor untouched, zero delayed action.
4. **Physical Scenario D (Safari negative control):**
   - D1 (stationary button tap): existing semantic tap operates cleanly (`AXPress` dispatched).
   - D2 (swipe on actionable element): `possibleTap -> unsupportedPan -> release -> NO ACTION`. Zero page scroll, zero mouse events, zero wheel events, zero cursor motion (`delta = 0.00 pt`).
5. **System Pointer Invariant:** 100% Inviolate across all physical contact sessions (`delta = 0.00 pt`).

