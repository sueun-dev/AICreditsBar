# Appearance and macOS diagnostic follow-up

Tested locally on macOS 27.0 (26A428), arm64, 2026-10-23. Battery measurement remains
deferred at the user's request. This follows the [previous investigation](diagnostics-2026-10-22.md).

## Fixed in this revision

The menu-bar image previously captured a fixed text color and replaced itself from
an `effectiveAppearance` observer. Runtime stacks showed that observer running
inside AppKit's `_redrawReplicantSnapshot` and variant-scene setup. AppKit temporarily
changes a status button's appearance to draw its replicas; mutating its image in
that callback caused unnecessary nested updates.

The image now resolves `labelColor` inside its drawing handler. It is reused across
appearance changes, and the observer is removed. A bitmap regression test reuses
one image through light/dark/light/dark drawings: before the fix, both light renders
incorrectly stayed white; afterward all four renders have contrasting ink.

| Controlled probe | Previous implementation | Updated implementation |
|---|---:|---:|
| One launch, 12 status-button appearance changes | 104 image assignments | 1 image assignment |
| Five launches with Settings, 60 total appearance changes | 394 image assignments | 5 image assignments |
| Historical layout-recursion warning in those five launches | 0 reproduced | 0 reproduced |

These probes used cached fixtures and disabled usage requests in a temporary copy
of AppDelegate. The counts include initialization. They measure image assignments,
not GPU frames or battery consumption. The historical layout warning itself is
still unreproduced; removing this reentrant path does **not** prove its cause or cure.
Earlier experiments changed only `NSApp.appearance`, which did not adequately
exercise status-button appearance changes.

The App Intents failures had a separate cause. Server-side `linkd` logs rejected the
ad-hoc binary because it had no Team ID. Re-signing the same probe with the locally
available Apple Development identity changed its three-second startup result from
nine registration errors to zero. The installed app additionally had a stale,
untrusted Launch Services record: signing alone left the errors, and force-refreshing
that app's registration removed them.

`build.sh` now selects an available Apple signing identity only when unambiguous,
supports an explicit `AICB_SIGN_IDENTITY` override, verifies the signature, and
refreshes Launch Services before restarting the login item. No certificates,
private keys, Team IDs, credentials, or account data are included in the repository.
Ad-hoc builds remain supported when no identity is available; the App Intents
warning may remain in that configuration. This is local signing, not notarization.

The final normal build restarted as PID 38772 at 00:17:15 America/Chicago. Its
startup log through 00:18:49 contained zero error/fault records. This interval
preceded opening/capturing Settings and does not mean every later OS diagnostic
has disappeared. The binary SHA-256 is
`503956d14b7a667adadcd15788f75d66f969ebf13d2fb09200b5294435c4bea9`.

## Remaining diagnostics and their evidence

| Diagnostic | New evidence | Remaining limit |
|---|---|---|
| Status-item scene invalidation and `BSBlockSentinel` | An independent program using only public AppKit APIs reproduced both while creating/removing status items. The checked-in runner produced 160 scene-invalidation messages and 200 sentinel messages, with no AICreditsBar source or networking. | Framework lifecycle reproduction established; the exact historical DarkWake sequence and an OS-level repair remain unverified. The app retains its status item rather than recreating it on refresh/wake. |
| WindowServer task-name port failure | A read-only breakpoint captured `BSMachPortTaskNameRight` → `BSProcessHandle` → `BSXPCServiceConnectionPeer` on the XPC worker path, targeting WindowServer PID 418. There were no application frames on this stack. | The framework's task-port request still fails. No permission or security protection was disabled. |
| Redacted accessibility messages | Read-only disassembly of `_NSAccessibilitySafeToVendElement` identified its lock-screen/shield checks and its call to `_NSAccessibilityLogUnsafeToVendElement`, the historical sender. Unlocked Settings remained accessible. | The historical private payload cannot distinguish the two guard branches. This is a screen-lock protection path, not evidence of an application data error. |
| Negative view width/height during capture | The prior independent NSWindow reproduction and sharing-indicator stack still apply; the signed installed app also reproduced the capture faults. | macOS sharing-indicator geometry remains unresolved. Removing or bypassing the sharing/privacy indicator is not an application fix. |
| One historical layout-recursion warning | Five baseline and five updated launches with Settings and actual status-button appearance changes exited successfully without hitting `_NSDetectedLayoutRecursion`. An earlier attached live run also did not hit it. | Exact original trigger remains unknown. No claim of a confirmed fix for this warning. |

Reproduce the independent status-item lifecycle case with:

```sh
bash Tests/diagnostics/run.sh status
```

It briefly creates/removes its own diagnostic status item, exits after eight seconds,
and removes its temporary bundle. The default `window` mode remains the 180-second
screen-sharing diagnostic. These are manual diagnostic reproducers, not tests that
assert the OS will emit no warnings. They do not load usage credentials or app settings.

## Validation

`bash Tests/run.sh` passed: 236 Swift assertions, five E2E scenarios, scoped process
restart checks, eight signing-selection cases, two resource-counter tests, and six
energy-tool tests. Normal build/signature verification and LaunchAgent restart also
passed. Dark/light menu previews were visually inspected; the installed Settings
controls and existing notification permission were checked through native accessibility.

On the updated signed application before the final rebuild, both providers refreshed
automatically after about 303 seconds without manual refresh. The timestamp-only
evidence is in the [machine-readable record](diagnostics-2026-10-23.json). Earlier
hour-long resource measurements concern the earlier build and are not presented as
fresh battery or performance measurements of this revision.

The final rebuilt PID 38772 also successfully refreshed both providers at about
05:22:19 UTC, over five minutes after its launch, without a manual refresh.

All log streams remained enabled. No private framework was patched or called to
alter behavior. The OS faults and the unreproduced historical warning above are
still open; passing tests and a clean startup interval do not establish their absence.
