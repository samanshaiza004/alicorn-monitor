# Dependencies

## Project Alicorn

`vendor/alicorn` is a Git submodule pinned to the Alicorn commit recorded by
the repository. The process monitor uses:

- `vendor/alicorn/runtime` for the procedural retained UI API;
- `vendor/alicorn/native/sdl_gpu` for the public SDL3/SDL_GPU application host.

The monitor does not import the foundation proof entrypoint and does not access
retained node maps, display lists, or native renderer internals.

## Odin and SDL3

The app uses the Odin toolchain and the SDL3 vendor directory shipped with the
selected Odin distribution. The Windows runner copies `SDL3.dll` beside the
executable because Windows does not search the Odin SDK vendor directory after
launch. On Darwin, the public Alicorn host requires the linked SDL3 runtime to
be exactly `3.4.16`; `tools/run.sh` reports that version and the host fails fast
if another SDL3 is selected. The validated Mac uses the arm64 Homebrew SDL3
package at `/opt/homebrew/opt/sdl3`.

## Runa

Runa remains Alicorn's vendored text dependency. The app consumes it indirectly
through Alicorn's public text runtime and does not own a second text stack.
