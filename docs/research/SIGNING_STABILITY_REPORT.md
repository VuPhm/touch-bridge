# Development signing handoff — September 27, 2026

## Result

The Accessibility identity failure is confirmed and the packaging cause is fixed.
The installed app is certificate-signed, verified, and running at
`/Users/vup/Applications/TouchBridge Dev.app`. Actual Accessibility authorization
is still pending the owner's one-time reauthorization. The most recent fresh
LaunchServices diagnostic returned `accessibilityTrusted: false`.

Two actual app packages have different code hashes but the same designated
requirement, and the later package satisfies the installed app's requirement.
**Permission retention across an authorized rebuild is not yet verified.**
Momentum UX acceptance also remains open.

## Repository and preservation

Branch: `main`. HEAD: `3681847a6896a3ec09971acad5204a8cb56ff9fd`.
The inherited tree contained 9 modified tracked files and 5 untracked files:

- `.gitignore`
- `Sources/TouchBridgeProbe/InteractionSession.swift`
- `Sources/TouchBridgeProbe/MenuBarController.swift`
- `Sources/TouchBridgeProbe/RuntimeValidator.swift`
- `Sources/TouchBridgeProbe/ScrollDeliveryBackend.swift`
- `Sources/TouchBridgeProbe/SemanticInteractionRouter.swift`
- `Sources/TouchBridgeProbe/TouchBridgeLogger.swift`
- `Sources/TouchBridgeProbe/TouchGestureRecognizer.swift`
- `p3_01_verification_evidence.json`
- `P3_05_FIELD_USE_EVIDENCE.md`
- `scratch/run_p3_05_field_pass.swift`
- `scratch/test_p3_06_momentum_verification.swift`
- `scratch/test_p3_06r_momentum_verification.swift`
- `scripts/build_dev_app.sh`

All remain byte-for-byte unchanged except `scripts/build_dev_app.sh`, which this
task updated. The inherited diff, copies, and SHA-256 manifest are preserved in
`build/signing-validation/inherited/`. No new worktree, checkout, stash, reset,
clean, commit, merge, or push was performed.

Files changed by this task:

- `scripts/build_dev_app.sh`: persistent certificate selection and fingerprint
  pinning; no ad-hoc fallback; timestamped build metadata; staging and strict
  verification; installed requirement compatibility check; retained backups;
  refuse running-app replacement unless `--restart` is requested.
- `scripts/dev_app_lifecycle.swift` (new): exact installed-executable matching,
  normal quit with bounded wait, no force kill or Automation permission.
- `scripts/test_dev_signing.sh` (new): different compiled code under one
  requirement, ad-hoc control failure, tamper rejection.
- `Sources/TouchBridgeProbe/main.swift`: read-only JSON permission diagnostic,
  including bundle identifier, path, PID, and actual process trust.
- `Sources/TouchBridgeProbe/AppDelegate.swift`: initial path/PID/trust logging
  and a two-second prompt-free refresh so the menu can reflect changed trust.
- `DEVELOPMENT_SIGNING.md` and this report (new).

## Confirmed root cause

The old script used `codesign --force --deep --sign -`. The installed bundle was
validly ad-hoc signed, with a designated requirement tied to its code hash.
Changed executable contents therefore fail the previously granted identity.

The system TCC log at 18:05:08 on September 27 recorded:

```
Failed to match existing code requirement for subject com.antigravity.touchbridge.dev and service kTCCServiceAccessibility
```

This is direct evidence, not a guess based solely on ad-hoc signing. TCC also
logged a mismatch for ListenEvent; no other Privacy permission was modified.
The bundle identifier and installed path were stable. PID 70235 was executing
that installed path, ruling out an alternate running copy for the observed
failure. The app's permission manager calls `AXIsProcessTrusted()` directly.
The Settings toggle state was reported by the owner, not independently inspected.
A second issue was stale UI state: the runtime did not periodically recheck
trust after the owner changed it in Settings.

`spctl` rejected the old local build. Gatekeeper assessment and TCC grants are
separate policies; this workflow does not attempt notarization or distribution.

## Signature before and after

Identifier in both: `com.antigravity.touchbridge.dev`.

Before: `Signature=adhoc`, no TeamIdentifier, no certificate.

```
# designated => cdhash H"74e5901b7be3f06179e3c5b0e57e7b0a26424157"
```

After: existing login-Keychain identity
`Apple Development: vuphamletruong@gmail.com (4QB2NXSMY6)`.
Certificate SHA-1: `1F6F2BACF5C0C8A8F28D50CD15865A1CE984322E`.
TeamIdentifier: `K85J2FN6ZT`. Certificate expires June 15, 2027, 21:48:28 UTC.

```
designated => identifier "com.antigravity.touchbridge.dev" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: vuphamletruong@gmail.com (4QB2NXSMY6)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

Installed package CDHash: `c4d7d9e4320ce51b9f923017a922861fee845c23`.
Second package CDHash: `01b6f9fc1bad5d3586063aa4c03e2b63c013db9a`.
Both have the identical requirement above. An additional regression compiles
two distinct Swift executables and confirms the same property across code changes.

No new certificate was created: the existing identity was sufficient. A local
self-signed Keychain alternative is documented for machines without an identity;
it was not provisioned/tested here. No Apple Developer membership was purchased
or required for this task. Future renewal or loss of this Keychain identity needs
explicit selection/recovery; the script will not silently switch identity.

The selected public fingerprint is pinned in
`~/Library/Application Support/TouchBridge/Development/signing-identity.sha1`.
No private key was exported. The initially inherited app is retained at
`/Users/vup/Applications/.touchbridge-backup.kjEMSQ/TouchBridge Dev.app`.

## Validation

- `swift build`: PASS.
- `TouchBridgeProbe --test-runtime`: 69/69 PASS.
- `TouchBridgeProbe --test-architecture`: 51/51 PASS, including backend latching,
  selected-backend momentum, mouse precedence, teardown, and contact quarantine.
- Release packaging/signature verification: PASS, repeated builds.
- Real rebuilt app satisfies installed designated requirement with changed
  CDHash: PASS.
- `scripts/test_dev_signing.sh`: PASS, including changed compiled code, ad-hoc
  regression control, and tampered Info.plist rejection.
- Missing identity: PASS, install fails with installed executable unchanged.
- Running app without `--restart`: PASS, refuses replacement with installed
  executable unchanged.
- `--install --restart`: PASS, normal termination, verified installation,
  backup retention, restart at the stable path.
- JSON diagnostic: PASS, stdout/file agree; missing argument returns 2; failed
  file write returns 1; LaunchServices result names the correct installed bundle.
- Latest actual app Accessibility: **false; owner grant pending**.
- Own tracked source diff whitespace check: PASS. Whole-tree diff check flags
  inherited trailing whitespace in InteractionSession/TouchBridgeLogger, untouched.

Build and test logs are under `build/signing-validation/`; runtime evidence was
written there instead of overwriting the inherited evidence JSON. Swift release
build reports the existing Swift 6 `@Sendable` warning in RollbackReproducer.
Sandbox-only probes could not access the Keychain/compiler caches and initially
reported no identity / trust errors; normal host-access checks succeeded.

The fixed-coordinate scratch momentum harnesses were inspected, not executed
against the owner's current desktop. They reimplement the decay math and some
cancellation cases and can report passes without a real target. The production
runtime/architecture momentum tests above passed. Neither those checks nor the
scratch scripts establish physical feel. No gesture tuning was changed.

## Remaining owner action and acceptance

Reauthorize only the installed TouchBridge Dev app in Accessibility; if its old
entry persists, remove that entry and add the installed copy. No TCC reset has
been executed. The narrow last-resort reset, only if needed and explicitly
approved/owner-run, is `tccutil reset Accessibility com.antigravity.touchbridge.dev`.
It is needed only if the stale identity cannot be repaired through Settings.

After a fresh LaunchServices diagnostic reports true, rebuild/install/relaunch
and confirm it is still true before declaring retention verified. The app is
currently running with the external touchscreen/display and saved calibration
recognized, and touch disabled as on every ordinary startup. Enable touch for
owner testing: slow drag little/no coast; ordinary flick visible short glide;
fast flick stronger but bounded; immediate new-touch cancellation; physical
mouse wins; Brave more conservative than AX surfaces. The accepted initial Brave
cursor hop is unchanged. Double-click and drag/drop were not started.

See [the workflow and commands](DEVELOPMENT_SIGNING.md).
