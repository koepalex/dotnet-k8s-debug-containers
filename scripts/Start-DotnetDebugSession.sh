#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
diag_script="$script_dir/Start-DotnetDiagSession.sh"

args=(
  --image ghcr.io/koepalex/dotnet-k8s-debug-containers/debug:latest
  --container-name-prefix dotnet-debug
  --add-capability SYS_PTRACE
  --run-as-root
)

exec "$diag_script" "${args[@]}" "$@"
