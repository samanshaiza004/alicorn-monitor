#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

odin_command=${ALICORN_ODIN:-odin}
case "$odin_command" in
	/*)
		if [ ! -x "$odin_command" ]; then
			echo "Odin executable not found: $odin_command" >&2
			exit 1
		fi
		;;
	*)
		odin_path=$(command -v "$odin_command" 2>/dev/null || true)
		if [ -z "$odin_path" ]; then
			echo "Odin executable not found on PATH: $odin_command" >&2
			exit 1
		fi
		odin_command=$odin_path
		;;
esac

git submodule update --init --recursive
mkdir -p out
"$odin_command" build . -out:out/alicorn-monitor
exec ./out/alicorn-monitor "$@"
