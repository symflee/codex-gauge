# Codex Gauge performance harness

Separate developer executable; no installed-app flags, telemetry, settings migration,
updater activity, or new dependencies. It runs a real `NSApplication` event loop and
registers an actual system status item, forwarding through the production presenter,
controller, renderer, menu, deadline scheduler, refresh coordinator and presentation
adapter. `empty` runs the same executable/dependencies with only the AppKit scaffold.

## Build and run

One owner must perform all builds/tests in a checkout. Build commands below are for
that owner; the harness neither builds nor installs anything itself.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --product codex-gauge-performance
.build/release/codex-gauge-performance --mode empty --duration 600 > /tmp/gauge-empty.jsonl
.build/release/codex-gauge-performance --mode idle --duration 600 > /tmp/gauge-idle.jsonl
.build/release/codex-gauge-performance --mode burst --duration 340 > /tmp/gauge-burst.jsonl
.build/release/codex-gauge-performance --mode rotation --duration 600 > /tmp/gauge-rotation.jsonl
.build/release/codex-gauge-performance --mode settings --duration 60 > /tmp/gauge-settings.jsonl
.build/release/codex-gauge-performance --mode menu --duration 10 > /tmp/gauge-menu.jsonl
.build/release/codex-gauge-performance --mode real --duration 600 > /tmp/gauge-real.jsonl
```

Use a logged-in macOS GUI session. Run one scenario at a time, under the same power,
appearance and display conditions, without opening its menu during an idle run.
Settings mode intentionally activates and displays the real settings window ten
times. Quit any separate Gauge development process when comparing CPU observations.
Use the equivalent `.build/debug/` binary for a matching development-build comparison.

`--mode` defaults to `idle`. Duration is integer seconds, defaults to 600 except
`burst` (340), `settings` (60), and `menu` (10), and must be 1...86400. Burst requires at least 340
seconds; settings requires at least 30 and menu at least 5. A rotation run must exceed one 5-second tick
to complete its scenario. Short idle/empty/real runs are useful for lifecycle smoke
checks but do not establish the ten-minute resource acceptance criteria.

For RSS attribution only, run these additional modes in separate processes:

```sh
.build/release/codex-gauge-performance --mode native --duration 30 > /tmp/gauge-native.jsonl
.build/release/codex-gauge-performance --mode badge --duration 30 > /tmp/gauge-badge.jsonl
.build/release/codex-gauge-performance --mode model --duration 30 > /tmp/gauge-model.jsonl
.build/release/codex-gauge-performance --mode menuShell --duration 30 > /tmp/gauge-menu-shell.jsonl
.build/release/codex-gauge-performance --mode menuAttached --duration 30 > /tmp/gauge-menu-attached.jsonl
.build/release/codex-gauge-performance --mode engine --duration 30 > /tmp/gauge-engine.jsonl
```

These records carry `diagnosticOnly: true`; `engine` uses
`providerKind: "synthetic_no_child_processes"`, while the other diagnostics above use
`providerKind: "none"`. These modes do
not replace `empty`, alter its initialization, or change any acceptance definition.
`scenarioCompleted` means the diagnostic setup executed; it does not pass a resource
gate. Their default duration is 600 seconds, so pass 30 explicitly for short probes.

## Scenarios

| Mode | Provider and behavior |
| --- | --- |
| `empty` | No status item, settings suite, provider, or refresh coordinator. Same linked binary dependencies. |
| `native` | Diagnostic only: a native `NSStatusItem` with fixed 48pt width and untouched empty button. No product presenter/controller/renderer, menu, date formatter, provider or settings. |
| `badge` | Diagnostic only: an actual system status item, production `SystemStatusItemPresenter` and `StatusItemController`, rendering one fixed synthetic frame through the production renderer and width prototypes. No menu/model/date formatter, provider/coordinator, settings or deadline scheduler. No rotation timer. |
| `menuShell` | Diagnostic only: identical badge setup plus one retained empty `NSMenu`, not assigned to the status item. No model, provider or menu controller. |
| `menuAttached` | Diagnostic only: identical `menuShell` setup, with that empty menu assigned to `statusItem.menu`. No model, provider or menu controller; the menu is not opened. |
| `engine` | Diagnostic only: the normal balanced synthetic provider and real refresh coordinator, retaining publications and counters. No status item, renderer, native menu, presentation-adapter work, model/date formatting, settings or deadline scheduler. Shutdown uses the same stop/termination barriers. |
| `model` | Diagnostic only: identical badge setup plus a cached synthetic publication matching idle, including two quota windows and `lastSuccessfulRefresh`. The real presentation adapter and `QuotaDetailsMenuModelCache` build the localized menu model once, exercising date formatting. No `NSMenu`, `StatusMenuController`, provider/coordinator, settings or deadline scheduler. |
| `idle` | Synthetic unchanged data, actual balanced startup and 180-second scheduling. No OS child processes. |
| `burst` | Synthetic integer growth. One manual read after startup, then real 20-second scheduling, 300-second cap and 180-second cooldown. An aggregate checkpoint 310 seconds after the second accepted response checks expiry, cooldown and zero live leases. |
| `rotation` | Two synthetic quota windows selected through the real presentation adapter and real 5-second rotation timer. Normal 180-second refreshes continue. |
| `settings` | Actual `SettingsWindowCoordinator` plus `SettingsWindowRuntimeAdapter`, ten visible open/close cycles, then idle. Weak references verify controller, window, view controller and view release. Diagnostics return metadata only; no CLI version probe, executable selection, login item changes or clipboard writes. |
| `menu` | Synthetic idle data, followed by two actual `NSMenu.popUp` tracking sessions. Each is canceled by one app-scoped timer. Checks zero rows/model requests before first open, one model request at first open, and unchanged native items with no additional model request at second open. Captures RSS before first open and after each close. |
| `real` | `CodexUsageProvider` and verified automatic `CodexExecutableLocator` discovery. Uses the existing account through the public App Server protocol. No authentication/configuration/private database files are inspected by the harness. No quota values, raw responses or executable paths are logged. |

All provider modes use balanced refresh and disable the coordinator's injected low
power flag for a repeatable 180/20-second comparison. The host's actual low-power
state is recorded, never changed. Power-event policy belongs to the parent app's
separate integration tests; this harness does not simulate sleep or lock events.
No clocks are accelerated. Synthetic sessions measure the app's scheduling and UI
cost only, and cannot establish the CPU cost of real App Server processes.

For attribution, `native - empty` probes the native status-item cost. `badge - native`
adds product badge text/bitmap rendering, width calculation, accessibility and
appearance handling; its width follows the real controller instead of the native
probe's fixed 48pt width. Closed `idle` retains the latest menu input and one deferred
provider, without creating its localized builder, formatting dates, or constructing
native rows. It still adds an empty attached menu, refresh actors and the initial
loading frame to `badge`.
`model - badge` isolates adding the publication/presentation adapter and menu-model
cache/date formatting without a native menu. `menu` measures the first-open cost
separately. Models, native rows and framework caches remain reusable after closing;
the unopened idle RSS reduction does not imply the same reduction after first open.
Shared framework initialization and resident-page effects mean the differences
are diagnostic observations, not independent allocation sizes to add together.
Compare RSS with RSS; physical footprint and `vmmap` categories supplement the
diagnosis and do not replace the existing 8 MiB RSS acceptance gate.

`menuShell - badge` probes retaining an empty native menu; `menuAttached - menuShell`
probes assigning it to the status item. `engine - empty` probes the synthetic refresh
actors without UI work. Run each separately under matching awake conditions. These
attribution probes do not prove independent/additive allocation sizes or replace
the full idle RSS measurement. An unopened lazy menu can have zero model requests;
do not attribute its RSS to Date.FormatStyle without the model diagnostic evidence.

## Output and interpretation

Standard output contains exactly two JSON lines on a completed run: `initial` and
`final`. The latter includes resource snapshots before and after cleanup, CPU-time
deltas divided by actual monotonic elapsed time, session counters, UI call counters
and optional burst/menu checkpoints. No per-tick logging or growing history is used.
`presentation.menuModelRequests` must stay zero during an unopened idle run. The
menu checkpoint records actual native tracking and model reuse, not just manual
delegate invocations.

- `appResidentBytes` is current resident memory from Mach task info;
  `appPeakResidentBytes` is Darwin's process-lifetime high-water mark from `getrusage`.
  Compare **current RSS at the end before cleanup** against `empty` from the same
  build/conditions. Peak RSS never decreases and is not a retained-memory reading.
- App CPU is `RUSAGE_SELF`. CPU percentages represent one fully occupied core, not
  a percentage divided by the machine's logical processor count. The initial snapshot occurs in applicationDidFinishLaunching: AppKit boot precedes the delta, while Gauge setup and the first read follow it. Snapshots also expose process-lifetime user/system totals. Use
  `measurement.appAverageCPUPercentOfOneCore` for the 10-minute idle CPU target.
- Child CPU is cumulative `RUSAGE_CHILDREN` for terminated/reaped owned children.
  `measurementIncludingCleanup` includes the final child's shutdown CPU. A live
  burst child may be absent from the **before-cleanup** child CPU total. These
  fields neither sample live child RSS nor prove coverage of all descendants.
- `sessions*` count logical leases, start attempts, accepted reads and confirmed
  closes. `maximumActiveLeases` is not an observed OS-process count. Synthetic mode
  leases represent virtual sessions and spawn zero children. To prove actual child
  start/count/overlap and live resource use, supplement real mode with an external
  process observation owned by the parent investigation. Do not infer OS children
  from synthetic counters or total RSS from app-only RSS.
- Presentation counters count calls entering the real renderer/presenter and
  callbacks delivered by the real appearance observer; they do not claim to count
  every internal AppKit property setter, raw KVO notification or frame draw.
- `scenarioCompleted` checks meaningful scenario execution and the single-read,
  single-lease invariants, plus timing validity below. It does **not** mean CPU/RSS acceptance has passed.
  The parent compares empty/idle, checks idle CPU <=0.1%, RSS growth <=8 MiB,
  balanced idle starts <=4 including startup, and checks real child observations.
- Missing optional metrics mean unavailable, never zero. A real run with a failed
  read is incomplete even if a later retry succeeds; inspect repeatability before
  treating its resource total as a normal idle result.

Exit status is 0 for a completed scenario with confirmed cleanup, 2 for incomplete
or interrupted measurement, 64 for invalid arguments. Errors never echo arguments
or provider payloads. `--help` prints usage only and does not initialize AppKit.

### Timing validity: reject sleep-contaminated or delayed runs

The additive `timingValidity` (before cleanup) and `timingIncludingCleanup` records
contain `continuousElapsedSeconds`, `awakeElapsedSeconds` from `SuspendingClock`,
`estimatedSleepSeconds = max(0, continuous - awake)`, `overrunSeconds`, and `isValid`.
Either elapsed overrun above **5 seconds** or estimated sleep above **1 second**
invalidates the run. Both records must be valid for `scenarioCompleted` to be true;
an invalid run exits 2 even if the functional scenario and process cleanup succeeded.
The same check applies to `empty` and diagnostic modes. No acceptance baseline or
CPU calculation is changed: CPU percentages still divide by continuous elapsed
time, never silently by awake time. Invalid averages must be excluded from reports.

Final measurement drivers must first require `scenarioCompleted == true`, confirmed
cleanup and both timing records' `isValid == true`, then apply CPU/RSS gates. The
external observer already rejects a false harness `scenarioCompleted`; its current
whitelist may omit the new timing records, so retain the direct harness report when
auditing sleep estimates. For older frozen binaries without these fields, check
actual elapsed against the requested duration (at most +5 seconds) and require
independent evidence that the host stayed awake; missing timing fields are not proof
of validity. In particular, 600-second runs lasting 11013 seconds and 340-second runs
lasting 1553 seconds are **INVALID** and their low CPU averages cannot be reused.

## Shutdown and isolation

One nonrepeating run-loop timer ends the requested duration. SIGINT, SIGTERM, the
menu's Quit action and AppKit termination all enter the same async cleanup path.
Cleanup cancels scenario work, awaits the actual coordinator's stop, confirms all
remaining owned session exits, shuts down settings, removes its unique defaults
suite, removes the system status item, and stops/wakes the application event loop.
An unconfirmed child keeps cleanup waiting for its exit event: the harness never
reports success or exits while claiming that child has been cleaned up.

Settings writes use a UUID-scoped `io.github.symflee.codex-gauge.performance.*`
defaults domain, never the installed application's domain. Normal cleanup removes
it. SIGKILL cannot run cleanup; avoid it. Output files are user-selected shell
redirection artifacts and can be deleted after the comparison.

`legacyModel` is an additional diagnostic using a reused DateFormatter with medium date/short time. It does not change the production formatter or the empty baseline. On this host it provided no material RSS improvement.
