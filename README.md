# Alicorn Monitor

A small Windows-first process monitor built as a separate dogfood application
for [Project Alicorn](https://github.com/samanshaiza004/alicorn).

The app deliberately uses only Alicorn's public runtime and native host
boundaries. It does not import the Alicorn proof executable or reach into its
renderer. Alicorn is pinned as a Git submodule at `vendor/alicorn`.

The current screen combines:

- system CPU and memory summaries;
- a retained 512-sample CPU graph;
- a keyed, fixed-height visible process table with fixed columns for PID,
  process name, CPU, working set (WS), and private commit;
- filtering, sorting, selection, keyboard navigation, and scrolling;
- Windows process sampling keyed by PID plus creation time.

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

The Alicorn SDK's SDL3 DLL must be beside the executable on Windows. The
repository's `tools/run.ps1` resolves Odin, validates that DLL, copies it to
`out`, builds the app, and launches it.

The process table deliberately shows both `WS` and `PRIVATE`. `WS` is resident
working-set memory and can include shared code and DLL pages; `PRIVATE` is the
process's private committed memory reported by `PrivateUsage`. Neither number
is a claim that process sampling itself consumes that much memory.

## Scope

This is intentionally not a task manager. It does not terminate processes,
show a process tree, load icons, expose GPU metrics, or claim cross-platform
sampling. Windows may deny access to protected processes; those rows are
skipped and counted.

The separate repository is itself a test: any missing public API, native-host
capability, or awkward ownership boundary should be fixed in Alicorn rather
than worked around here.
