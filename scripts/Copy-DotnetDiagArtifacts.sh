#!/usr/bin/env bash

set -euo pipefail

pod=
container_name=
remote_path=
destination=
namespace=default
mount_path=/diag
shell=/bin/sh
termination_timeout_seconds=60
terminate_container=false
what_if=false

usage() {
  cat <<'EOF'
Usage: Copy-DotnetDiagArtifacts.sh --pod POD --container-name NAME \
  --remote-path PATH --destination PATH [options]

Options:
  --namespace NAMESPACE                  Kubernetes namespace (default: default)
  --mount-path PATH                      Diagnostics mount root (default: /diag)
  --shell PATH                           Container shell (default: /bin/sh)
  --termination-timeout-seconds SECONDS  Termination timeout from 1 to 600
  --terminate-container                  Exit the ephemeral container after cleanup
  --what-if, --dry-run                   Validate and print the planned operation
  -h, --help                             Show this help
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_value() {
  local option=$1
  local value=${2-}
  [[ -n $value ]] || fail "$option requires a non-empty value."
}

normalize_container_path() {
  local path=$1
  local parameter_name=$2
  local segment
  local -a segments=()

  [[ $path == /* ]] || fail "$parameter_name must be an absolute Linux container path."

  IFS='/' read -r -a raw_segments <<< "$path"
  for segment in "${raw_segments[@]}"; do
    [[ -z $segment || $segment == . ]] && continue
    if [[ $segment == .. ]]; then
      ((${#segments[@]} > 0)) ||
        fail "$parameter_name cannot traverse above the container root."
      segments=("${segments[@]:0:${#segments[@]}-1}")
      continue
    fi
    segments+=("$segment")
  done

  local normalized=/
  if ((${#segments[@]} > 0)); then
    local joined
    printf -v joined '/%s' "${segments[@]}"
    normalized=$joined
  fi
  printf '%s\n' "$normalized"
}

get_pod() {
  kubectl get pod "$pod" --namespace "$namespace" --output json
}

while (($# > 0)); do
  case $1 in
    --pod)
      require_value "$1" "${2-}"
      pod=$2
      shift 2
      ;;
    --container-name)
      require_value "$1" "${2-}"
      container_name=$2
      shift 2
      ;;
    --remote-path)
      require_value "$1" "${2-}"
      remote_path=$2
      shift 2
      ;;
    --destination)
      require_value "$1" "${2-}"
      destination=$2
      shift 2
      ;;
    --namespace)
      require_value "$1" "${2-}"
      namespace=$2
      shift 2
      ;;
    --mount-path)
      require_value "$1" "${2-}"
      mount_path=$2
      shift 2
      ;;
    --shell)
      require_value "$1" "${2-}"
      shell=$2
      shift 2
      ;;
    --termination-timeout-seconds)
      require_value "$1" "${2-}"
      termination_timeout_seconds=$2
      shift 2
      ;;
    --terminate-container)
      terminate_container=true
      shift
      ;;
    --what-if|--dry-run)
      what_if=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ -n $pod ]] || fail "--pod is required."
[[ -n $container_name ]] || fail "--container-name is required."
[[ -n $remote_path ]] || fail "--remote-path is required."
[[ -n $destination ]] || fail "--destination is required."
[[ $termination_timeout_seconds =~ ^[0-9]+$ ]] &&
  ((termination_timeout_seconds >= 1 && termination_timeout_seconds <= 600)) ||
  fail "--termination-timeout-seconds must be an integer from 1 to 600."

command -v kubectl >/dev/null 2>&1 || fail "kubectl was not found on PATH."
command -v jq >/dev/null 2>&1 || fail "jq was not found on PATH."

mount_path=$(normalize_container_path "$mount_path" "MountPath")
remote_path=$(normalize_container_path "$remote_path" "RemotePath")

[[ $mount_path != / ]] || fail "MountPath cannot be the container root."
[[ $remote_path != "$mount_path" && $remote_path == "$mount_path/"* ]] ||
  fail "RemotePath must identify a file or directory below MountPath '$mount_path'; the mount root itself cannot be copied and deleted."
[[ ! -e $destination && ! -L $destination ]] ||
  fail "Destination '$destination' already exists. Choose a new path so the copied result can be verified before remote cleanup."

destination_parent=$(dirname -- "$destination")
[[ -d $destination_parent ]] ||
  fail "Destination parent directory '$destination_parent' does not exist."

pod_json=$(get_pod)
[[ $(jq -r '.metadata.deletionTimestamp // empty' <<< "$pod_json") == "" ]] ||
  fail "Pod '$namespace/$pod' is terminating."

ephemeral_count=$(jq --arg name "$container_name" \
  '[.spec.ephemeralContainers[]? | select(.name == $name)] | length' \
  <<< "$pod_json")
((ephemeral_count == 1)) ||
  fail "Ephemeral container '$container_name' was not found in Pod '$namespace/$pod'."

running=$(jq -r --arg name "$container_name" '
  [.status.ephemeralContainerStatuses[]?
    | select(.name == $name)
    | (.state.running != null)]
  | first // false
' <<< "$pod_json")
[[ $running == true ]] ||
  fail "Ephemeral container '$container_name' is not running. Files in its root filesystem are unavailable, and this Pod mounts the diagnostics volume only in that container."

read -r -d '' path_check_script <<'EOF' || true
set -eu
path=$1
[ -e "$path" ] || [ -L "$path" ]
EOF

kubectl exec "pod/$pod" \
  --namespace "$namespace" \
  --container "$container_name" \
  -- "$shell" -c "$path_check_script" -- "$remote_path" >/dev/null

action="Copy '$remote_path' to '$destination', delete the exact remote path"
if [[ $terminate_container == true ]]; then
  action+=", and terminate ephemeral container '$container_name'"
fi

if [[ $what_if == true ]]; then
  echo "Would operate on '$namespace/$pod': $action."
  exit 0
fi

echo "Copying '$namespace/$pod:$remote_path' to '$destination'..."
kubectl cp "$namespace/$pod:$remote_path" "$destination" --container "$container_name" >/dev/null

[[ -e $destination || -L $destination ]] ||
  fail "kubectl cp completed, but destination '$destination' was not created. The remote artifact was not deleted."

read -r -d '' remove_script <<'EOF' || true
set -eu
path=$1

if [ ! -e "$path" ] && [ ! -L "$path" ]; then
  echo "Remote path no longer exists: $path" >&2
  exit 44
fi

rm -rf -- "$path"

if [ -e "$path" ] || [ -L "$path" ]; then
  echo "Remote path still exists after deletion: $path" >&2
  exit 45
fi
EOF

echo "Removing exact remote path '$remote_path'..."
kubectl exec "pod/$pod" \
  --namespace "$namespace" \
  --container "$container_name" \
  -- "$shell" -c "$remove_script" -- "$remote_path" >/dev/null

echo "Copied artifact to '$destination' and removed '$remote_path'."

[[ $terminate_container == true ]] || exit 0

echo "Requesting termination of ephemeral container '$container_name'..."
set +e
attach_output=$(printf 'exit\n' | kubectl attach "pod/$pod" \
  --namespace "$namespace" \
  --container "$container_name" \
  --stdin 2>&1)
attach_exit_code=$?
set -e

deadline=$((SECONDS + termination_timeout_seconds))
terminated_state=
while ((SECONDS < deadline)); do
  pod_json=$(get_pod)
  terminated_state=$(jq -c --arg name "$container_name" '
    .status.ephemeralContainerStatuses[]?
    | select(.name == $name)
    | .state.terminated // empty
  ' <<< "$pod_json" | head -n 1)
  [[ -n $terminated_state ]] && break
  sleep 1
done

if [[ -z $terminated_state ]]; then
  fail "Artifact copy and remote cleanup succeeded, but ephemeral container '$container_name' did not terminate within $termination_timeout_seconds seconds. kubectl attach exit code: $attach_exit_code. $attach_output"
fi

termination_reason=$(jq -r '.reason // empty' <<< "$terminated_state")
termination_exit_code=$(jq -r '.exitCode // empty' <<< "$terminated_state")
echo "Ephemeral container '$container_name' terminated (reason: $termination_reason; exit code: $termination_exit_code). Its immutable Pod record remains until the Pod is replaced."
