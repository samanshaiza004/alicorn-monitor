# macOS validation

This report records the physical-Mac validation of Alicorn Monitor originally
performed on `port/macos-monitor-c6746ce` and carried into `master`. It is
deliberately evidence-based; a passing build is not treated as proof of native
behavior.

## Baseline

| Item | Result |
| --- | --- |
| Monitor starting commit | `c6746cec03418f1ef763d99f97235d7463f6e189` |
| Monitor branch | `port/macos-monitor-c6746ce` |
| Pinned Alicorn starting commit | `3f1fcd76a8c1518bb6ba751f5bbde6da31d8880e` |
| Validated Alicorn commit | `2cf4bc449af954a5c4daeaf0efc833b237eddcef` (current `master` pin; includes event fix `2b079fc`, SDL 3.4.16 policy, bounded virtual-list geometry, and subsequent runtime fixes) |
| Host | MacBook Air 10,1, Apple M1, 8 cores, 8 GB |
| macOS | 26.6.2 (25G83) |
| Architecture | `arm64` / Apple Silicon |
| Display | Built-in Retina, 2560 x 1600 |
| Odin | `dev-2026-09-nightly:a2fb372` |
| SDL3 | Pinned/required `3.4.16`; the binary links `/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib` |
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
SDL3/SDL_GPU retained compositor: PASS resize_iterations 300 submissions 303 retired 303 display_commands 6 max_frames_in_flight 3 fence_waits 303 fence_query_before_wait_true 2 fence_query_after_wait_true 303 logical_resize_events 300 pixel_resize_events 301 scale_events 1 text_input_events 1 composition_events 1 text_shape_calls 306 text_glyph_cache_hits 12015 text_glyph_cache_misses 63 text_rasterizations 63 text_atlas_pages 1 text_quads 36 text_atlas_full_page_uploads 2 text_atlas_upload_bytes 8388608 text_readback_non_background 881 text_input_boundary focus-start-caret-area-stop pointer_adapter logical coordinates unchanged logical_to_physical compositor boundary only
```

The retained Alicorn submodule pin is the newer merged `master` commit shown
above. It contains the public Metal assertion/selection, macOS activation work,
the current native diagnostics seam, the latest runtime input/presentation
changes, the bounds-toggle wake fix, and the newer allocator/resource/runtime
fixes. It does not expose renderer internals to the monitor.

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

The current candidate executable is:

```text
/Users/keina/dev/alicorn-monitor/out/alicorn-monitor-next
```

The validated run from the merged latest-master executable completed
successfully:

```text
sdl3_version 3 4 16
gpu_driver_requested metal gpu_driver_selected metal
SDL application PASS submissions 18 retired 18 max_frames_in_flight 2 wall_ns 3002049000 logical_resize_events 0 pixel_resize_events 1 text_input_events 0 composition_events 0 text_change_dispatches 0 text_changes 0 text_edit_key_events 0 text_navigation_key_events 0 text_selection_key_events 0 text_word_key_events 0 events_per_pump_max 2 oldest_event_age_max_ns 82665875 input_to_submit_p95_ns 85145292 input_to_submit_max_ns 276176459 text_mesh_rebuilds 10 text_mesh_cache_hits 8 text_vertex_uploads 10 frame_p95_ns 1496000 gpu_encode_ns 168399000 gpu_submit_ns 443000 fence_wait_ns 4354000 application_tick_max_ns 5083000 application_build_max_ns 28078000 gpu_encode_max_ns 31732000 fence_wait_max_ns 4337000
process_monitor PASS samples 10 rows 355 cpu_percent 21.1 memory_used 7.8 GB memory_total 8.0 GB identity_keys 355 surface_updates 10 surface_frames 10 graph_points 512 graph_latest_percent 21.1 graph_min_percent 0.0 graph_max_percent 58.6 graph_current_delta_percent 0.0 projection_rebuilds 11 query_failures 2025
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
| Public app proof did not report selected SDL GPU driver | `Run` requested Metal but did not assert or print the selected driver | Alicorn history through `2b079fc` verifies `metal` and reports the linked SDL version in the public host on Darwin | Monitor output reports `sdl3_version 3 4 16` and `gpu_driver_requested metal gpu_driver_selected metal`. |
| The visible bare SDL window became non-interactive on the physical Mac | `SDL_PollEvent` enters SDL's Cocoa pump, while the earlier Darwin workaround bypassed SDL's `NSApplication.sendEvent` activation/dispatch path | Darwin now calls `SDL_PumpEvents` once and drains the translated queue with `SDL_PeepEvents`; non-Darwin hosts retain `SDL_PollEvent` | The exact rebuilt Monitor run reported `WINDOW_FOCUS_GAINED`, then steady `app_active true key_window true sdl_input_focus true`, plus mouse, key, and text-input events. |
| First sampler smoke aborted with an invalid free | A PID slice allocated with `context.temp_allocator` was deleted through the default allocator | Explicitly delete the temporary PID slice with `context.temp_allocator` | LLDB no longer observes the malloc abort; smoke exits 0. |
| macOS had no native launcher | Only the PowerShell runner existed | Added executable `tools/run.sh`; Windows `tools/run.ps1` remains unchanged | `./tools/run.sh --smoke` passes. |
| Darwin process names were clipped at the short command-name limit | The sampler read `pbi_comm` (`MAXCOMLEN`) even when the longer registered name was available | Prefer `pbi_name` and fall back to `pbi_comm` | Sampler output now includes names longer than 16 characters, including `AssetCacheLocatorService`. |
| Virtual-list scrolling entered a large blank tail and skipped rows twice | Realized rows already started at `first`, while the container also applied the full scroll offset | Expose and apply only `leading_offset_y`; include scroll in the layout hash and dirty layout ancestors when child order changes | Alicorn virtual-list bounds tests pass at row-aligned and fractional offsets. |
| Scrolling and other interaction rebuilds repeated the full process filter/sort projection | The monitor rebuilt `visible` on every application description build | Cache the projection by process revision, filter, sort, and direction | Monitor self-test passes; native diagnostics report projection rebuild count separately. |
| CPU history could be mistaken for the current CPU value | The graph had no visible latest/max context | Add graph latest/max diagnostics and header context; retain the normalized sample invariant | Three native runs reported `graph_current_delta_percent 0.0`; graph maxima remained within 0–100%. |

## Latest native diagnostics

The new Alicorn diagnostics tool is useful for this failure. Running the
merged executable with `--diagnostics --capture-after=1
--capture-dir=/tmp/alicorn-monitor-diagnostics-latest` produced valid
`diagnostics.json`, `inspector.txt`, and `screenshot.ppm`. The capture recorded:

```text
gpu_driver metal
logical 960 x 720; physical 1920 x 1440; density 2; display scale 2
retained nodes 144; display commands 228; focused node = filter field
surface updates 1; surface frames consumed 1
```

The inspector showed the filter field with the expected bounds and focus, and
the sort buttons and process rows as retained hit-testable nodes. This makes
the diagnostics tool useful for separating retained-layout/input-state bugs
from host event delivery. With the event-pump fix, the timed one-second
capture fires without another event. The prior `sample` of the old host path
showed the main thread in `SDL_WaitEventTimeoutNS` /
`Cocoa_PumpEventsUntilDate`; the corrected run stayed interactive and reported
AppKit active/key-window state as true.

An exact-binary `--input-debug` session also observed:

```text
sdl_event WINDOW_FOCUS_GAINED
sdl_event WINDOW_FOCUS_LOST
sdl_event WINDOW_FOCUS_GAINED
darwin_focus app_active true key_window true sdl_input_focus true
sdl_event MOUSE_BUTTON ...
sdl_event KEY_DOWN ...
sdl_event TEXT_INPUT text h
```

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
- A complete scripted UX checklist was not automated, but the exact rebuilt
  executable now reports active AppKit/key-window/SDL focus and accepts mouse,
  keyboard, and text-input events during a live diagnostic session.
- Real macOS IME composition and OS candidate UI positioning remain unproven.
- No separate 30–60 second performance sample or allocator telemetry was
  added. The latest bounded smoke showed 11 samples, 11 graph updates, and
  bounded two-frame GPU retirement. The current smoke also reports projection
  rebuilds and graph latest/min/max values.
- libproc is private/compatibility-sensitive on macOS.

## Recommendation

**REVISE**

The physical Apple Silicon session proves the current Alicorn renderer,
Metal selection, Retina contract, real process sampling, and bounded GPU host
behavior. Automated evidence removes the prior main-thread SDL/Cocoa stall;
the exact corrected executable still needs a human interaction pass before
this branch can be called cross-platform dogfood-ready. Keep this branch at
**REVISE** pending that pass.
