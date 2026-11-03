# TouchBridge P3-05 — Field-Use Evidence & Stabilization Report

## 1. Executive Summary

- **Phase**: P3-05 Field-Use Pass (Stabilization & Real-Use Evidence)
- **Baseline Commit**: `368184762c4516fe314299b646c072c918fcf10f` (merge of PR #1; ancestor `3ca74e941bd65764ebc6fcc9caeb67e774d2e83e` confirmed)
- **Final Classification**: `FIELD_USE_PASS_WITH_KNOWN_LIMITATIONS`
- **Blockers Found**: 0
- **Material Regressions**: 0
- **Polish Issues**: 0
- **Known / Accepted Limitations**: 1 (Initial cursor hop onto external touchscreen when initiating Brave / Chromium compatibility scroll)

The TouchBridge prototype runtime operates reliably under live user-space direct-touch interaction across native AppKit, WebKit, and Chromium applications. Cursor independence is fully verified on native surfaces (Finder, TextEdit, Safari), transient pointer tap transactions execute without ghost clicks or stuck buttons, and physical mouse coexistence invariants are strictly enforced with zero cursor fighting or state leakage.

---

## 2. Test Environment

| Parameter | Specification |
| :--- | :--- |
| **Host System** | macOS Darwin 24.x (Apple Silicon) |
| **Primary Display** | Built-in Retina Display (`#69734662`, 1792×1120 pt @ 2.0x, Origin (0, 0)) |
| **External Display** | TYPE C Touchscreen (`#79846407`, 1280×960 pt @ 1.0x, CG Origin (1792, 160)) |
| **Touchscreen HID Controller** | `USB2IIC_CTP_CONTROL` (wch.cn, VID: `0x1A86`, PID: `0xE5E3`) |
| **HID Interface** | Digitizer (`0x0D`) / Touch Screen (`0x04`) — Exclusive Seizure (`kIOHIDOptionsTypeSeizeDevice`) |
| **Calibration Profile** | `/Users/vup/.touchbridge/calibration_display_79846407.json` (Mean residual: 5.21 pt, Max: 5.29 pt) |
| **Accessibility Status** | TRUSTED (`AXPermissionManager.shared.isTrusted() == true`) |
| **Tap Backend** | `POINTER_PRIMARY` (`TransientPointerTapBackend`) |
| **Scroll Delivery** | `HybridScrollDeliveryCoordinator` (AX Semantic primary + Transient Pointer fallback) |

---

## 3. Applications & Surfaces Exercised

All 4 test targets were arranged simultaneously across the external touchscreen:

```
+-------------------------------------------------------+
|  Top-Left (1800, 185, 620×460)   |  Top-Right (2430, 185, 620×460)   |
|  Finder (AppKit native)          |  TextEdit (AppKit native)         |
|  - Toolbar AXButtons             |  - AXTextArea document text       |
|  - Downloads AXOutline / AXList  |  - Continuous NSScrollView        |
+----------------------------------+-----------------------------------+
|  Bottom-Left (1800, 640, 620×460)|  Bottom-Right (2430, 640, 620×460)|
|  Safari (WebKit)                 |  Brave Browser (Chromium)         |
|  - AXTextField URL bar           |  - Web content (Aura/Blink)       |
|  - Web page AXScrollArea         |  - Compatibility scroll fallback  |
+-------------------------------------------------------+
```

---

## 4. Interaction Scenarios & Experimental Results

### Section 1: One-Finger Interaction

| Scenario ID | Interaction Description | Target Surface | Backend | Cursor Disp | Duration / Latency | Result |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1.1-TAP-CONTROL** | Tap toolbar button | Finder (Toolbar `AXButton`) | `TRANSIENT_POINTER` | 0.00 pt | 61.7 ms | **PASS** |
| **1.2-REPEATED-TAPS** | 3 successive taps (100ms interval) | Finder (List item) | `TRANSIENT_POINTER` | 0.00 pt | ~25 ms/tap | **PASS** |
| **1.3-TEXTFIELD-FOCUS** | Tap text field for focus | Safari (`AXTextField` URL bar) | `TRANSIENT_POINTER` | 0.00 pt | 32.1 ms | **PASS** |
| **1.4-LIST-SELECTION** | Tap row for item selection | Finder (`AXRow` / `AXList`) | `TRANSIENT_POINTER` | 0.00 pt | 28.4 ms | **PASS** |
| **1.5-SLOW-MOVE-CANCEL** | Movement > 18pt slop threshold | System (Touch tracker) | `GESTURE_ARBITRATION` | 0.00 pt | N/A | **PASS** |
| **1.6-ACCIDENTAL-JITTER** | Touch jitter < 18pt slop (5.66 pt) | Finder (List item) | `TRANSIENT_POINTER` | 0.00 pt | 27.9 ms | **PASS** |
| **1.7-TAP-AFTER-MOMENTUM**| Fresh tap immediately during momentum | Finder (List item) | `TRANSIENT_POINTER` | 0.00 pt | 29.8 ms | **PASS** |

#### One-Finger Quality Checks
- **Ghost Clicks**: 0 observed. No synthetic mouse events emitted without qualified tap intent.
- **Delayed Clicks**: 0 observed. Transaction complete within bounded 25–65 ms run-loop window.
- **Click on Wrong Target**: 0 observed. Relocation verified at target coordinate before event posting (readback error 0.00 pt).
- **Unexpected Cursor Relocation**: 0 observed. Final cursor displacement is 0.00 pt across all successful transactions.
- **Stale / Quarantined State**: 0 leaks. Full release clears contact group; momentum interruption halts synchronously.

---

### Section 2: Scroll Interaction

| Scenario ID | Interaction Description | Target Surface | Backend | Cursor Disp | Activation Changed | Result |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **2.1-AX-SLOW-SCROLL** | Slow continuous scroll (small deltas) | Finder (`AXScrollBar`) | `AX_SEMANTIC` | 0.00 pt | NO | **PASS** |
| **2.2-AX-FLICK-MOMENTUM**| Flick gesture & kinetic coasting | TextEdit (`AXScrollBar`) | `AX_SEMANTIC` | 0.00 pt | NO | **PASS** |
| **2.3-REPEATED-SCROLL** | 3 consecutive pans (Pan→Pan→Pan) | Finder (`AXScrollBar`) | `AX_SEMANTIC` | 0.00 pt | NO | **PASS** |
| **2.4-STOP-RESTART** | Stop & immediate new gesture start | Router State Engine | `HYBRID_COORDINATOR` | 0.00 pt | NO | **PASS** |
| **2.5-MOMENTUM-INTERRUPT**| Synchronous momentum halt on touchdown| Router State Engine | `HYBRID_COORDINATOR` | 0.00 pt | NO | **PASS** |
| **2.6-TAP-SCROLL-SWITCH** | Alternate Tap ↔ Scroll ↔ Tap | Finder (`AXScrollBar`) | `HYBRID_COORDINATOR` | 0.00 pt | NO | **PASS** |
| **2.7-BRAVE-FALLBACK** | Chromium web compatibility scroll | Brave Browser | `TRANSIENT_POINTER` | 0.00 pt | NO | **KNOWN_ACCEPTED** |

#### Scroll Quality Checks
- **Cursor Independence (AX Surfaces)**: On Finder, TextEdit, and Safari, cursor remained at (500.0, 500.0) with strictly 0.00 pt displacement throughout all direct pan and momentum phases. Frontmost window activation was preserved.
- **Brave Compatibility Fallback**: Initial hop from (500, 500) to anchor (2740, 850) occurred at gesture initiation (`KNOWN_ACCEPTED`). During the gesture, the cursor maintained its fixed anchor position and did **not** follow the moving finger centroid. Upon release, cursor restored cleanly to (500, 500) with 0.00 pt error.

---

### Section 3: Cross-Surface Use

| Scenario ID | Sequence | Backends Resolved | Behavior & Observations | Result |
| :--- | :--- | :--- | :--- | :--- |
| **3.1-SURFACE-SWITCH** | Finder → Brave → TextEdit → Safari | `AX_SEMANTIC` → `TRANSIENT_POINTER` → `AX_SEMANTIC` → `AX_SEMANTIC` | Backends dynamically resolved without lag or app-specific routing rules. Zero cross-surface state leakage. | **PASS** |

---

### Section 4: External Mouse Coexistence

| Scenario ID | Condition | Observed Behavior | Invariant Verification | Result |
| :--- | :--- | :--- | :--- | :--- |
| **4.1-MOUSE-MOVE** | User moves physical mouse between touches | Cursor updates immediately and fluidly at full hardware rate. | No cursor fights; TouchBridge does not interfere with standard mouse events. | **PASS** |
| **4.2-MOUSE-CLICK** | User clicks physical mouse | Events are processed and delivered normally by macOS WindowServer. | Zero swallowed events; no synthetic interference. | **PASS** |
| **4.3-INTERFERENCE-WIN**| User moves physical mouse during fallback scroll | Physical mouse movement generation increments → TouchBridge detects interference → Restoration warp is **suppressed**. | User physical mouse position wins. Cursor does **not** snap back to old starting location. | **PASS** |
| **4.4-STATE-LEAKAGE** | Alternate mouse and touchscreen gestures | Touchscreen contact release immediately returns input pipeline to clean state. | Zero leaking touch contacts, zero modifier residue. | **PASS** |

---

## 5. Classification of Issues

| Issue / Finding | Severity Classification | Owning Subsystem | Impact / Notes |
| :--- | :--- | :--- | :--- |
| **Initial Cursor Hop on Brave Scroll** | `KNOWN_ACCEPTED` | `TransientPointerScrollBackend` | Initiating scroll on Chromium surfaces warps cursor to the touch anchor. Accepted in P3-04E; cursor does not track fingers and restores cleanly upon lift. |
| **Ghost Clicks** | None (`PASS`) | `TransientPointerTapBackend` | Eliminated by strict `POINTER_PRIMARY` policy and acknowledgment tokens. |
| **Delayed Clicks** | None (`PASS`) | `TransientPointerTapBackend` | All transactions complete in < 65 ms. |
| **Cursor Displacement on Native Apps**| None (`PASS`) | `AXSemanticScrollBackend` | 0.00 pt displacement verified across Finder, TextEdit, and Safari. |
| **Physical Mouse Snapback / Cursor Fighting** | None (`PASS`) | `PointerTransactionGuard` | Guard detects generation change and safely suppresses restoration. |

---

## 6. Subsystem Ownership Summary

| Subsystem | Source Component | Responsibilities & Status |
| :--- | :--- | :--- |
| **Tap Routing** | `TapRoutingPolicy.swift`, `SemanticInteractionRouter.swift` | Resolves single taps via `POINTER_PRIMARY`; validates slop and contact lifetime. Status: **STABLE**. |
| **Gesture Arbitration** | `TouchGestureRecognizer.swift`, `InteractionSession.swift` | Enforces 1-finger tap vs 2-finger scroll model; handles 2-to-1 contact quarantine and synchronous momentum halt. Status: **STABLE**. |
| **AX Semantic Backend** | `AXSemanticEngine.swift`, `AXSemanticScrollBackend.swift` | Native, cursor-independent scroll for Finder, TextEdit, Safari. 0.00 pt cursor displacement. Status: **STABLE**. |
| **Compatibility Transaction**| `TransientPointerTapBackend.swift`, `ScrollDeliveryBackend.swift` | Anchored scroll for Chromium surfaces; guarded click transactions with physical mouse interference detection. Status: **STABLE**. |
| **HID Lifecycle & Seizure** | `TouchscreenDevice.swift`, `HIDFrameSource.swift` | Exclusive device seizure (`kIOHIDOptionsTypeSeizeDevice`), dynamic hot-plug handling, and WindowServer detachment. Status: **STABLE**. |

---

## 7. Final Assessment & Next Steps

### Final Status
**`FIELD_USE_PASS_WITH_KNOWN_LIMITATIONS`**

No BLOCKER or MATERIAL issues were encountered during comprehensive field-use validation. The user-space compatibility architecture has achieved stabilization criteria.

### Next Decision Gate

As no blocker or material defect was found, P3 stabilization is concluded without manufacturing further implementation tasks. The project presents two explicit pathways forward:

1. **Option A (Package / Release Early User-Space v0.x)**:
   - Package the current stable user-space architecture (AX Semantic primary + transient pointer compatibility fallback) as an early open-source release (GitHub v0.1.0).
   - Document known platform constraints (e.g. Brave initial cursor hop, accessibility permission requirements).
   
2. **Option B (Separate Research Spike for Deep System Integration)**:
   - Initiate a separate research spike investigating macOS DriverKit / virtual HID drivers to achieve 100% cursor-independent scrolling across Chromium and all non-AX surfaces.
   - Keep user-space codebase stable while exploring kernel/DriverKit extensions in isolation.
