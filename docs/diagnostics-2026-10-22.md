# macOS diagnostic investigation and energy measurement

Local date: 2026-10-22, America/Chicago. Raw timestamps use UTC (2026-10-23).

See the [2026-10-23 follow-up](diagnostics-2026-10-23.md) for the appearance/signing
fixes and additional evidence. The results below describe the earlier build.

The screen-sharing geometry fault was independently reproduced in a minimal
AppKit program with no AICreditsBar source, networking, status item, or custom
layout. Changing the title-bar or resizing options did not reliably prevent it.
The diagnostic messages have **not all been resolved**. No application source
change was made merely to hide or suppress them.

## Diagnostic findings

| Message | Observed evidence | Status |
|---|---|---|
| Negative view width/height | Six of each occurred in the independent AppKit window during capture. The symbolicated stack enters `NSThemeFrame._positionSharingIndicator`, `NSWindowSharingSessionRecipientIndicator`, and `windowSelectiveSharingStateChangedNotification`. | Reproduced in macOS's sharing-indicator path; remains present. |
| Unable to obtain a task name port | The target PID resolves to WindowServer. The same message occurs in the independent AppKit program. | System-framework access failure; no security settings changed. |
| `com.apple.linkd.autoShortcut` connection errors | The independent program reports the same AppIntents registration failures both when launched directly and through Launch Services (`open`). AICreditsBar does not implement App Intents. | Execution through `open` did not resolve the system-service failure. |
| Status-item scene invalidation / `BSBlockSentinel` | Historical events coincide with the recorded DarkWake at 22:32:36 local time. AICreditsBar's wake handler refreshes data; it does not destroy/recreate the status item. | Exact OS scene-lifecycle trigger remains unconfirmed; no controlled sleep reproduction or claimed fix. |
| Redacted AppKit messages | The recorded sender address resolves to `_NSAccessibilityLogUnsafeToVendElement`. | Logging location identified; the private message body does not establish a precise cause or a repair. |
| Layout recursion warning | One earlier startup emitted `_NSDetectedLayoutRecursion`. Three isolated startup/appearance experiments and a 20-second debugger launch of the installed application did not hit that breakpoint. The subsequent login-agent startup also emitted no matching warning in the captured interval. | Historical warning remains unexplained and unreproduced; absence on restart is not a fix. |

The first standard-title-bar probe appeared clean, but did not show the sharing
indicator. Repeating with a separate app identifier and a visible sharing indicator
reproduced twelve geometry faults. That first result was therefore not accepted
as evidence of a workaround.

The independent reproduction is [Tests/diagnostics/main.swift](../Tests/diagnostics/main.swift).
`bash Tests/diagnostics/run.sh` builds a temporary, signed AppKit-only app and prints
its PID. Capture its window and inspect unified logs for that PID. It exits after
180 seconds and cleans up the temporary bundle. Opening a window without capturing
it does not by itself reproduce the sharing-indicator fault.

## Measured resources

The installed binary remained unchanged during measurement:
`1fead906c9754deae9d61be6fc838236f7c02ea73885c510423192a68e183747`.
App sources match the previously tested `cd25761` implementation; later commits
add measurement tools and evidence.

| Measurement | Result | Scope |
|---|---|---|
| Kernel-attributed CPU energy | 0.594657611 J over 599.878 measured seconds | Main app process only; about 0.9913 mW averaged over this interval. |
| Task GPU-time increase | 0 ns | App counter only. WindowServer's rendering is excluded. |
| CPU time in a separate 15-minute run | 0.88381525 s; 0.0982% of one core on average | Includes the diagnostic inspection period; not an idle-only benchmark. |
| Physical memory footprint | 46.11 MiB initially, 46.63 MiB finally, 53.91 MiB sampled maximum | Main process, with UI capture activity during the run. |
| Actual battery discharge | **Not measured** | AC remained connected; the user could not disconnect it. |

The energy interval ran from 04:26:43 UTC for approximately ten minutes. Settings
was initially visible; Done was clicked during the beginning of this interval.
The tool records both kernel counters and actual battery power-source flags.
All 41 samples reported external power, no charging, and zero battery current.
This is an AC-powered process-energy measurement, **not a battery-life test**.

The task counters follow [Apple's XNU task accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c#L6395-L6403).
The battery reader uses the [documented current and voltage units](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/IOKit/pwr_mgt/IOPMPowerSource.h#L103-L111).
Sampled battery Wh is whole-computer current/voltage integration, not an external
meter measurement or an attribution to this app. No battery-runtime extrapolation
is made from the CPU-energy figure.

## Validation and remaining work

`bash Tests/run.sh` passed: 228 Swift assertions, five E2E scenarios, process restart
scoping, two CPU-measurement tests, and six energy-measurement tests. The energy
tests cover an independent known Wh calculation, signed current decoding, exclusion
of AC/sleep/clock gaps, refusal of AC when battery measurement is required, and a
live counter sampling interval, and a Mac without an internal battery. This does not claim that an unplugged battery run
has occurred.

After debugger inspection, the existing login agent was restored and one installed
app process was running. Both providers remained enabled at a five-minute interval.

To obtain an actual unplugged run later:

```sh
python3 Tests/measure_energy.py <APP_PID> --seconds 900 \
  --require-battery --output battery.json
```

It fails explicitly on AC and marks missing battery coverage incomplete. A single
whole-computer run still cannot isolate this app's incremental battery cost from
other processes, display brightness, network activity, and measurement overhead.

The [machine-readable record](diagnostics-2026-10-22.json) contains the measurements,
probe summaries, symbolicated geometry stack, and current limits. Raw local logs
were retained separately; no private message text, credentials or quota values are
published in this record.
