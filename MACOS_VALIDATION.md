# macOS validation

This report records the physical-Mac validation of Alicorn Monitor on the
`port/macos-monitor-c6746ce` branch. It is deliberately evidence-based; a
passing build is not treated as proof of native behavior.

## Baseline

| Item | Result |
| --- | --- |
| Monitor starting commit | `c6746cec03418f1ef763d99f97235d7463f6e189` |
| Monitor branch | `port/macos-monitor-c6746ce` |
| Pinned Alicorn starting commit | `3f1fcd76a8c1518bb6ba751f5bbde6da31d8880e` |
| Validated Alicorn commit | `96e0a001fd3a6f363f34ecbf402d189810b67596` |
| Host | MacBook Air 10,1, Apple M1, 8 cores, 8 GB |
| macOS | 26.6.2 (25G83) |
| Architecture | `arm64` / Apple Silicon |
| Display | Built-in Retina, 2560 x 1600 |
| Odin | `dev-2026-09-nightly:a2fb372` |
| SDL3 | Homebrew `3.4.14`; the binary links `/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib` |
| GPU | Apple M1 GPU, Metal 4 |

The monitor working tree was clean at the starting commit. Alicorn was changed
in its own repository and then pinned here as a separate submodule update.

## Alicorn foundation before monitor work

Commands run from `vendor/alicorn` with the installed Odin nightly:

| Command | Result | Notes |
| --- | --- | --- |
| `./tools/check.sh` | PASS | Headless foundation suite passed unchanged. |
| `./tools/bench.sh` | PASS | 1,000,000 logical rows retained 23 nodes; 1,200 surface-only updates performed no ordinary rebuild work. |
| `./tools/native_sdl_gpu.sh` | PASS | Real retained Metal composition, GPU text, surface rendering, resize, fences, and shutdown. |

The current native fixture reported:

```text
gpu_driver_requested metal gpu_driver_selected metal
window_metrics initial logical 640 x 480 pixels 1280 x 960 pixel_density 2 display_scale 2
window_metrics resize logical 801 x 601 pixels 1602 x 1202 pixel_density 2 display_scale 2
window_metrics resize logical 640 x 480 pixels 1280 x 960 pixel_density 2 display_scale 2
SDL3/SDL_GPU retained compositor: PASS resize_iterations 300 submissions 303 retired 303 display_commands 6 max_frames_in_flight 3 fence_waits 303 fence_query_before_wait_true 301 fence_query_after_wait_true 0 logical_resize_events 300 pixel_resize_events 301 scale_events 1 text_input_events 1 composition_events 1 text_shape_calls 305 text_glyph_cache_hits 12015 text_glyph_cache_misses 63 text_rasterizations 63 text_atlas_pages 1 text_quads 36 text_atlas_full_page_uploads 2 text_atlas_upload_bytes 8388608 text_readback_non_background 881 text_input_boundary focus-start-caret-area-stop pointer_adapter logical coordinates unchanged logical_to_physical compositor boundary only
```

The Alicorn changes in `8de9a8e` and `96e0a00` make the public `Run` host
print/assert the selected driver on Darwin and explicitly foreground/raise a
bare SDL window for keyboard and mouse input. They do not expose renderer
internals to the monitor.

## Monitor build and smoke

The unmodified monitor built successfully once its ignored `out/` directory
was created. Before the sampler existed, the unmodified smoke run launched the
window and reported zero rows, as designed:

```text
process_monitor PASS samples 0 rows 0 surface_updates 0 surface_frames 0 query_failures 0
```

The new Unix path is:

```sh
ALICORN_ODIN=/Users/keina/Documents/odin-macos-arm64-nightly+2026-09-01/odin ./tools/run.sh --smoke
```

The validated run completed successfully:

```text
gpu_driver_requested metal gpu_driver_selected metal
SDL application PASS submissions 3 retired 3 max_frames_in_flight 3 wall_ns 3004397000 logical_resize_events 0 pixel_resize_events 1 scale_events 1 text_input_events 0 composition_events 0
process_monitor PASS samples 12 rows 364 cpu_percent 30.1 memory_used 7.9 GB memory_total 8.0 GB identity_keys 364 surface_updates 12 surface_frames 12 query_failures 2306
```

This proves that the same application host creates a Retina window, selects
Metal, renders through the current retained Alicorn compositor, samples real
processes, updates system CPU and memory, and advances the GPU surface only
when samples arrive. The query-failure count is cumulative: inaccessible or
already-exited processes are skipped rather than aborting the application.

## Darwin sampler contract

Enumeration and per-process queries use Odin's Darwin bindings for Apple's
libproc interfaces (`proc_listallpids`, `proc_pidinfo`, and
`proc_pid_rusage`). `libproc.h` is explicitly marked private by the Apple SDK,
so this is suitable for a normal desktop validation build but is not an App
Store/public-API compatibility guarantee. The declarations and use are
isolated in `process_darwin.odin`; no libproc types cross into the application
boundary.

The retained process key is:

```text
PID + ri_proc_start_abstime
```

`ri_proc_start_abstime` is the process-start identity returned with the same
rusage query as the cumulative CPU and memory metrics. CPU deltas and retained
selection are keyed by this value, never by table position. The smoke output
observed `rows == identity_keys` after repeated sampling. A forced PID recycle
fixture was not run.

Metric meanings:

- Process CPU is the delta of `ri_user_time + ri_system_time`, divided by the
  monotonic sample interval and by 8 logical processors. `100%` means the
  whole machine, matching the Windows presentation convention.
- System CPU is computed from `host_statistics(HOST_CPU_LOAD_INFO)` tick
  deltas for user, system, nice, and idle time. It is not the sum of visible
  processes.
- `RESIDENT` is `ri_resident_size`.
- `FOOTPRINT` is `ri_phys_footprint`; it is not labeled as Windows private
  commit.
- System memory uses `hw.memsize` and `host_statistics64(HOST_VM_INFO64)`:
  `total - free_pages * host_page_size`. The UI labels this **non-free**
  memory because it includes reclaimable/cache pages and intentionally does
  not claim to reproduce Activity Monitor's formula.

## Fixes made

| Symptom | Root cause | Change | Regression evidence |
| --- | --- | --- | --- |
| Darwin built the intentional empty sampler | The fallback was `!windows`, so it also compiled on macOS | Added `process_darwin.odin` and excluded Darwin from `process_other.odin` | Monitor builds and samples 364 rows on this Mac. |
| macOS process rows had no native metrics | No Darwin enumeration or rusage implementation existed | Added libproc-backed enumeration, start identity, CPU deltas, resident/footprint metrics, system CPU ticks, and host VM memory | Smoke reported nonzero rows, CPU, memory, stable key count, and repeated samples. |
| Darwin labels would have claimed Windows semantics | Shared UI used `WS` and `PRIVATE` unconditionally | Darwin displays `RESIDENT` and `FOOTPRINT`; system memory is labeled non-free | Compiled/run on the physical Retina Mac. |
| Public app proof did not report selected SDL GPU driver | `Run` requested Metal but did not assert or print the selected driver | Alicorn commit `8de9a8e` verifies `metal` in the public host on Darwin | Monitor output reports `gpu_driver_requested metal gpu_driver_selected metal`. |
| The visible bare SDL window became non-interactive on the physical Mac | The window could render and sample while macOS input ownership was still ambiguous | Alicorn commit `96e0a00` sets the macOS foreground/activation hints before SDL initialization and raises the created window | The retest still reproduced the symptom; raw SDL event delivery remains under investigation. |
| First sampler smoke aborted with an invalid free | A PID slice allocated with `context.temp_allocator` was deleted through the default allocator | Explicitly delete the temporary PID slice with `context.temp_allocator` | LLDB no longer observes the malloc abort; smoke exits 0. |
| macOS had no native launcher | Only the PowerShell runner existed | Added executable `tools/run.sh`; Windows `tools/run.ps1` remains unchanged | `./tools/run.sh --smoke` passes. |

## Retina, lifecycle, text, and thread observations

The Alicorn foundation fixture measured logical 640 x 480 against physical
1280 x 960 at pixel density and display scale 2, then completed 300 logical
resize iterations and 301 pixel-size events. Pointer coordinates remained in
logical units and conversion occurred only at the compositor boundary. The
monitor uses the same public host and passes logical dimensions to layout and
GPU-surface creation; it does not scale pointer data in app code.

The current foundation fixture proves the SDL text-input boundary and a
synthetic composition event. The monitor smoke itself received no text-input
events. A human-operated Japanese/Chinese IME composition, candidate-window
placement, and end-to-end filter edit were not automated in this run.

SDL window, event, text-input, and GPU operations remain owned by Alicorn's
main-thread host. The Darwin sampler is called synchronously from the existing
tick callback; no worker thread or direct runtime mutation was introduced.

## Known gaps

- No Intel Mac or second display was tested.
- No forced PID-recycle test was run; the implementation uses the documented
  start-time identity and repeated samples retained matching keys.
- Manual retest on the physical Mac reports that the window renders for less
  than a second, then filter typing, buttons, row selection, and arrow-key
  navigation stop responding; the native close control still works. The
  supplied screenshot shows readable process rows and live-looking metrics but
  no successful interaction after startup. This is an unresolved gate failure,
  not a passing interaction result.
- Real macOS IME composition and OS candidate UI positioning remain unproven.
- No separate 30–60 second performance sample or allocator telemetry was
  added. The bounded smoke showed 12 samples, 12 graph updates, and bounded
  three-frame GPU retirement.
- libproc is private/compatibility-sensitive on macOS.

## Recommendation

**REVISE**

The physical Apple Silicon session proves the current Alicorn renderer,
Metal selection, Retina contract, real process sampling, and bounded GPU host
behavior. The main loop continues sampling, but manual input is still
unreliable after startup. Keep this branch at **REVISE** until raw SDL focus,
mouse, keyboard, and text events are observed and the monitor controls work in
the same run.
