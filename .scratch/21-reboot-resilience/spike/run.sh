#!/usr/bin/env bash
# Runs the ticket #01 experiments inside the disposable container (rootless podman, own netns).
# Usage: ./run.sh [build|e7]   — 'build' (re)builds the image first; 'e7' runs the exposure-window measurement.
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -ne 0 ]] || { echo "refusing to run as root: use rootless podman (a rootful privileged container is far more dangerous)" >&2; exit 2; }
if [[ "${1:-}" == "build" ]]; then podman build -t hermes-spike-docker -f Containerfile .; shift; fi
script=experiments.sh; [[ "${1:-}" == "e7" ]] && script=e7-window.sh
exec podman run --rm --privileged --network=private --name hermes-spike \
  -e SPIKE_IN_DISPOSABLE_CONTAINER=1 -e E7_CYCLES="${E7_CYCLES:-10}" \
  -v "$PWD:/spike:ro" \
  hermes-spike-docker bash /spike/$script
