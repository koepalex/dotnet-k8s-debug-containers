#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker build -f "$repo_root/docker/Dockerfile.diag" -t dotnet-k8s-diag:local "$repo_root"
docker build -f "$repo_root/docker/Dockerfile.debug" -t dotnet-k8s-debug:local "$repo_root"
