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
launch.

## Runa

Runa remains Alicorn's vendored text dependency. The app consumes it indirectly
through Alicorn's public text runtime and does not own a second text stack.
