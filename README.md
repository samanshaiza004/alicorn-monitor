# Alicorn Monitor

A small Windows + macOS process monitor built as a separate dogfood application
for [Project Alicorn](https://github.com/samanshaiza004/alicorn).

The app deliberately uses only Alicorn's public runtime and native host
boundaries. It does not import the Alicorn proof executable or reach into its
renderer. Alicorn is pinned as a Git submodule at `vendor/alicorn`.

The current screen combines:

- system CPU and memory summaries;
- a retained 512-sample CPU graph;
- a keyed, fixed-height visible process table with fixed columns for PID,
  process name, CPU, and platform-truthful memory metrics;
- filtering, sorting, selection, keyboard navigation, and scrolling;
- Windows process sampling keyed by PID plus creation time;
- continuous fixed-height scrolling with a proportional position indicator;
- Darwin process sampling keyed by PID plus `ri_proc_start_abstime`.
- a 250 ms system-summary/graph refresh and a 1 s opportunistic process-table
  refresh; table work yields briefly after keyboard or pointer activity.

Keyboard-only operation is part of the dogfood contract: `Tab`/`Shift+Tab`
traverse active controls, while `Enter`/`Space` activate a focused button.
The process summary reports rows successfully queried in the latest sample and
adds an `unavailable` count when a process exited or could not be queried.

## Build

Install Odin and initialize the pinned dependency:

```powershell
git submodule update --init --recursive
.\tools\run.ps1
```

For a bounded native smoke run:

```powershell
.\tools\run.ps1 -Smoke
```

For the monitor-side public text callback test:

```powershell
.\tools\run.ps1 -SelfTest
```

This exercises adoption of committed insertion, Backspace, Delete, selection
replacement, and no-op `Text_Change` ownership through the monitor's callback.

For a machine-readable interaction/performance capture:

```powershell
.\tools\run.ps1 -Diagnostics -CaptureAfter 5 -CaptureDir out\diagnostics
```

The capture includes frame-time percentiles and maximums, event bursts, event
queue age, and input-to-submit latency. Press `F12` while the app is running
to capture on demand; `F11` toggles retained bounds for layout debugging.

The Alicorn SDK's SDL3 DLL must be beside the executable on Windows. The
repository's `tools/run.ps1` resolves Odin, validates that DLL, copies it to
`out`, builds the app, and launches it.

On macOS, use the Unix launcher:

```sh
git submodule update --init --recursive
ALICORN_ODIN=/path/to/odin ./tools/run.sh
```

Use `./tools/run.sh --smoke` for a bounded GUI run. The script uses Odin from
`ALICORN_ODIN` or `PATH` and does not install system packages. macOS uses
SDL3's Metal backend through Alicorn's public native host.

On Windows the process table shows `WS` and `PRIVATE`: resident working-set
memory and private committed memory reported by `PrivateUsage`. On macOS it
shows `RESIDENT` and `FOOTPRINT`, backed by `ri_resident_size` and
`ri_phys_footprint`. These are intentionally not presented as equivalent
cross-platform metrics.

## Scope

This is intentionally not a task manager. It does not terminate processes,
show a process tree, load icons, expose GPU metrics, or package/notarize the
application. Windows and macOS may deny access to protected processes; those
rows are skipped and counted. Darwin enumeration uses Apple's libproc
interfaces through Odin's Darwin bindings; Apple marks those interfaces
private and subject to change, so this is desktop validation rather than an
App Store/public-API guarantee.

The separate repository is itself a test: any missing public API, native-host
capability, or awkward ownership boundary should be fixed in Alicorn rather
than worked around here.
