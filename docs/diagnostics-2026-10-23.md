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
| Five further launches, each with 40 synthetic provider results and 12 appearance changes | 746 image assignments | 205 image assignments |

These probes used cached fixtures and disabled usage requests in a temporary copy
of AppDelegate. The counts include initialization. They measure image assignments,
not GPU frames or battery consumption. The historical layout warning itself is
still unreproduced; removing this reentrant path does **not** prove its cause or cure.
Earlier experiments changed only `NSApp.appearance`, which did not adequately
exercise status-button appearance changes.

The additional provider-result probe exercises callbacks arriving during startup
using offline fixtures above the alert threshold. Both implementations processed
200 callbacks across five successful launches, without hitting the layout-recursion
breakpoint. The updated version assigns one initial image plus one per changed
provider result. This stress case also did not recover the original warning's trigger.

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

## Available OS update

The host's Software Update check offered macOS 27.0.1 (26A434), a 3,235,867 KiB
download requiring a restart. The update has not been installed by this task.
[Apple's release listing](https://developer.apple.com/news/releases/?id=09282026c)
confirms that build. Its [general release notes](https://support.apple.com/en-us/127257)
state that it contains bug fixes, and the
[enterprise notes](https://support.apple.com/en-us/148830) identify a Platform SSO
lock-screen fix. Neither inspected page identifies these AppKit warnings as repaired.
An update would therefore be a new environment to test, not an established fix.

All log streams remained enabled. No private framework was patched or called to
alter behavior. The OS faults and the unreproduced historical warning above are
still open; passing tests and a clean startup interval do not establish their absence.

## Resumed investigation and sleep-clock correction

A fresh read at 08:09 America/Chicago covered PID 38772 from its 00:17:15 launch.
The roughly 7-hour-52-minute interval contained nine error/fault entries: the
previous task-port failure and six capture-geometry entries, one InputAnalytics
connection interruption, and one redacted accessibility message. There were no
App Intents, scene-invalidation, or layout-recursion entries in that interval.
This is a retrospective log check, not a continuous performance measurement.

Read-only symbolication placed the new accessibility entry in
`_NSAccessibilityLogUnsafeToVendElement`, the same lock/shield protection path
described above. The InputAnalytics entry came from the interruption logging block
inside `IAXPCClient.initWithServiceName`; its server-side interruption cause was
not recovered. Editing a Settings field also emitted a ViewBridge cancellation
(code 18). The field remained usable and its original five-minute value was restored.
Neither message is claimed to be repaired or conclusively harmless in all contexts.

The sharing-indicator fault is now narrowed to actual input values. In the installed
app, a read-only breakpoint immediately after the indicator's `intrinsicContentSize`
call recorded six `(-1, -1)` results and five `(66, 20)` results. AppKit's
`NSThemeFrame._positionSharingIndicator` passes that size directly to `setFrameSize`.
Disassembly of `NSWindowSharingSessionRecipientIndicator.intrinsicContentSize` shows
the `(-1, -1)` fallback when both checked internal references are nil. The captured stack
runs through AppKit's sharing-state/appearance initialization, with no application
layout callback. This explains the observed negative sizes; it is not an OS repair.
The sharing indicator was left visible and all debugger attachments were detached.

The live-state check also found an old Claude reading. Inspection of the running
app identified **expired Claude Code login**, with no in-flight request or active
429 backoff. A separate CLI request succeeded after the credential became valid;
the running app then automatically refreshed both providers at approximately
13:17:10 UTC and cleared the error, without a manual menu refresh. The app did not
rotate or write credentials. This authentication interruption is separate from the
clock defect below; `pmset` recorded no system sleep during this observation interval.

Code review found that `RefreshController` used `systemUptime` for both its minimum
request gap and 429 deadlines. That clock counts awake time. Consequently, sleeping
does not consume a retry delay, and a long sleep just after a request can still
leave the post-wake request blocked by the minimum gap. The default clock now uses
`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`, which advances during sleep and is
independent of wall-clock corrections. The API is available before the app's macOS
11 deployment target. See Apple's documentation for
[systemUptime](https://developer.apple.com/documentation/foundation/processinfo/systemuptime)
and [continuous time](https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time).

`Tests/refresh-clock/run.sh` compiles the real controller with deterministic platform
clock stand-ins, leaving its default clock argument intact. The previous source
fails two assertions: refresh after an hour asleep, and expiration of a five-minute
backoff including sleep. The corrected source passes all five assertions, including
retaining a backoff when a short sleep has not exhausted it. The full suite also
passes: 236 existing Swift assertions, five E2E scenarios, process scoping, eight
signing cases, two resource tests, and six energy-tool tests. Actual hardware
sleep/wake with this new build has not been tested; the Mac was not put to sleep.

This clock fix does not claim to remove the remaining macOS diagnostics or identify
the exact historical layout-recursion trigger. No OS update was installed.

The normal build signed and restarted the updated app as PID 90938 at 08:22:09
America/Chicago. Both providers saved successful readings at approximately 13:22:10
UTC and again at 13:27:40 UTC without manual refresh. The intervals were 329.874
seconds for Codex and 329.778 seconds for Claude, within the existing five-minute
timer plus its 10% tolerance. Error/fault logs through 13:28:25 UTC contained zero
entries for this process. This short interval did not include window capture or
hardware sleep and does not establish that the known OS warnings are fixed.
The updated binary SHA-256 is
`67f13728025e0b37b90118904c273aeff9eb38d5cb034d0b687b06dfd480d7fa`.
