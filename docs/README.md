# Alicorn Monitor documentation

This repository is a dogfood application for [Project Alicorn](https://github.com/samanshaiza004/alicorn).
It is intentionally kept separate so the monitor must consume Alicorn through
the public package boundaries rather than importing a proof executable or
reaching into renderer internals.

## Public boundary under test

The pinned `vendor/alicorn` submodule supplies:

- `vendor/alicorn/runtime`: retained UI description, input, text, and surface
  APIs;
- `vendor/alicorn/native/sdl_gpu`: `alicorn_sdl_gpu.Application` and `Run`, a
  small SDL3/SDL_GPU application host.

The host owns the window, event pump, render passes, swapchain, text renderer,
surface renderer, and deferred GPU-resource retirement. The monitor owns only
ordinary process state and callback behavior. Its state pointer is borrowed by
the host for callback duration and is never retained by Alicorn's runtime
nodes.

## Evidence

Run the bounded smoke test from the repository root:

```powershell
.\tools\run.ps1 -Smoke
```

The output reports host submissions and retirement, while the monitor reports
samples, visible rows, graph updates, and Windows process-query failures. The
last value is expected to be nonzero on many systems because protected
processes can reject limited query access.

The table reports `WS` (working set) and `PRIVATE` (private committed memory)
separately. A large working set can include shared pages from SDL, the Odin
runtime, graphics drivers, and loaded fonts; it is not equivalent to private
application allocation.

## Deliberate limits

This is a Windows-first v0. It does not terminate processes, show a process
tree, load icons, expose GPU metrics, or provide a cross-platform sampler.
Those omissions are intentional: the application exists to test the public
Alicorn boundary and the coexistence of changing process data, keyed rows,
text input, and a live GPU surface.
