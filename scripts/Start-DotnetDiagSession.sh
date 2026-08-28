#!/usr/bin/env bash

set -euo pipefail

pod=
target_container=
namespace=default
image=ghcr.io/koepalex/dotnet-k8s-debug-containers/diag:latest
container_name=
container_name_prefix=dotnet-diag
volume_name=diagnostics
mount_path=/diag
shell=/bin/sh
startup_timeout_seconds=60
run_as_root=false
skip_socket_discovery_validation=false
no_attach=false
what_if=false
add_capabilities=()

usage() {
  cat <<'EOF'
Usage: Start-DotnetDiagSession.sh --pod POD --target-container CONTAINER [options]

Options:
  --namespace NAMESPACE                 Kubernetes namespace (default: default)
  --image IMAGE                         Diagnostics image
  --container-name NAME                 Explicit ephemeral container name
  --container-name-prefix PREFIX        Generated name prefix (default: dotnet-diag)
  --volume-name NAME                    Pod emptyDir volume (default: diagnostics)
  --mount-path PATH                     Container diagnostics mount (default: /diag)
  --shell PATH                          Container shell (default: /bin/sh)
  --startup-timeout-seconds SECONDS     Startup timeout from 1 to 600 (default: 60)
  --add-capability CAPABILITY           Add a Linux capability; repeat as needed
  --clear-capabilities                  Remove capabilities set by a wrapper
  --run-as-root                         Run as UID 0 with an unconfined seccomp profile
  --no-run-as-root                      Do not add the root security context
  --skip-socket-discovery-validation    Continue if no .NET socket can be prepared
  --no-attach                           Leave the primary shell running without attaching
  --what-if, --dry-run                  Print the Pod payload without creating the container
  -h, --help                            Show this help
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

quote_command() {
  local quoted
  printf -v quoted '%q ' "$@"
  printf '%s' "${quoted% }"
}

while (($# > 0)); do
  case $1 in
    --pod)
      require_value "$1" "${2-}"
      pod=$2
      shift 2
      ;;
    --target-container)
      require_value "$1" "${2-}"
      target_container=$2
      shift 2
      ;;
    --namespace)
      require_value "$1" "${2-}"
      namespace=$2
      shift 2
      ;;
    --image)
      require_value "$1" "${2-}"
      image=$2
      shift 2
      ;;
    --container-name)
      require_value "$1" "${2-}"
      container_name=$2
      shift 2
      ;;
    --container-name-prefix)
      require_value "$1" "${2-}"
      container_name_prefix=$2
      shift 2
      ;;
    --volume-name)
      require_value "$1" "${2-}"
      volume_name=$2
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
    --startup-timeout-seconds)
      require_value "$1" "${2-}"
      startup_timeout_seconds=$2
      shift 2
      ;;
    --add-capability)
      require_value "$1" "${2-}"
      add_capabilities+=("$2")
      shift 2
      ;;
    --clear-capabilities)
      add_capabilities=()
      shift
      ;;
    --run-as-root)
      run_as_root=true
      shift
      ;;
    --no-run-as-root)
      run_as_root=false
      shift
      ;;
    --skip-socket-discovery-validation|--skip-diagnostic-port-validation)
      skip_socket_discovery_validation=true
      shift
      ;;
    --no-attach)
      no_attach=true
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
[[ -n $target_container ]] || fail "--target-container is required."
[[ $startup_timeout_seconds =~ ^[0-9]+$ ]] &&
  ((startup_timeout_seconds >= 1 && startup_timeout_seconds <= 600)) ||
  fail "--startup-timeout-seconds must be an integer from 1 to 600."
[[ ${#container_name_prefix} -le 57 &&
  $container_name_prefix =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  fail "--container-name-prefix must be a valid DNS label with at most 57 characters."

command -v kubectl >/dev/null 2>&1 || fail "kubectl was not found on PATH."
command -v jq >/dev/null 2>&1 || fail "jq was not found on PATH."

mount_path=$(normalize_container_path "$mount_path" "MountPath")
[[ $mount_path != / ]] ||
  fail "MountPath cannot be the container root because the emptyDir mount would hide the diagnostics image filesystem."

pod_json=$(kubectl get pod "$pod" --namespace "$namespace" --output json)

[[ $(jq -r '.metadata.deletionTimestamp // empty' <<< "$pod_json") == "" ]] ||
  fail "Pod '$namespace/$pod' is terminating."

target_count=$(jq --arg name "$target_container" \
  '[.spec.containers[]? | select(.name == $name)] | length' <<< "$pod_json")
if ((target_count != 1)); then
  available_containers=$(jq -r '[.spec.containers[]?.name] | join(", ")' <<< "$pod_json")
  fail "Target container '$target_container' was not found in Pod '$namespace/$pod'. Available containers: $available_containers"
fi

volume_count=$(jq --arg name "$volume_name" \
  '[.spec.volumes[]? | select(.name == $name)] | length' <<< "$pod_json")
((volume_count == 1)) ||
  fail "Pod '$namespace/$pod' does not declare volume '$volume_name'. Add a shared emptyDir volume to the workload template first."

is_empty_dir=$(jq -r --arg name "$volume_name" \
  '[.spec.volumes[]? | select(.name == $name) | has("emptyDir")] | first // false' \
  <<< "$pod_json")
[[ $is_empty_dir == true ]] ||
  fail "Pod volume '$volume_name' must be an emptyDir volume so the diagnostics container can create the Unix socket and collected artifacts."

if [[ -z $container_name ]]; then
  while :; do
    suffix=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-5)
    container_name="$container_name_prefix-$suffix"
    existing_count=$(jq --arg name "$container_name" \
      '[.spec.ephemeralContainers[]? | select(.name == $name)] | length' \
      <<< "$pod_json")
    ((existing_count == 0)) && break
  done
fi

[[ ${#container_name} -le 63 &&
  $container_name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  fail "Ephemeral container name '$container_name' must be a valid DNS label with at most 63 characters."

existing_count=$(jq --arg name "$container_name" \
  '[.spec.ephemeralContainers[]? | select(.name == $name)] | length' \
  <<< "$pod_json")
((existing_count == 0)) ||
  fail "Ephemeral container '$container_name' already exists in Pod '$namespace/$pod'. Ephemeral containers cannot be restarted or replaced."

capabilities_json='[]'
if ((${#add_capabilities[@]} > 0)); then
  capabilities_json=$(printf '%s\n' "${add_capabilities[@]}" | jq -R . | jq -s .)
fi
ephemeral_container=$(jq -n \
  --arg name "$container_name" \
  --arg image "$image" \
  --arg shell "$shell" \
  --arg target "$target_container" \
  --arg volume "$volume_name" \
  --arg mount "$mount_path" \
  --argjson capabilities "$capabilities_json" \
  --argjson run_as_root "$run_as_root" '
    {
      name: $name,
      image: $image,
      command: [$shell],
      stdin: true,
      tty: true,
      targetContainerName: $target,
      env: [{name: "TMPDIR", value: $mount}],
      volumeMounts: [{name: $volume, mountPath: $mount}]
    }
    + if (($capabilities | length) > 0 or $run_as_root) then
        {
          securityContext:
            ({}
              + if $run_as_root then {
                  runAsUser: 0,
                  runAsNonRoot: false,
                  allowPrivilegeEscalation: true,
                  seccompProfile: {type: "Unconfined"}
                } else {} end
              + if ($capabilities | length) > 0 then {
                  capabilities: {add: $capabilities}
                } else {} end)
        }
      else {} end
  ')

payload=$(jq --argjson container "$ephemeral_container" \
  '.spec.ephemeralContainers = ((.spec.ephemeralContainers // []) + [$container])' \
  <<< "$pod_json")

if [[ $what_if == true ]]; then
  jq -c . <<< "$payload"
  exit 0
fi

encoded_namespace=$(jq -rn --arg value "$namespace" '$value | @uri')
encoded_pod=$(jq -rn --arg value "$pod" '$value | @uri')
resource_path="/api/v1/namespaces/$encoded_namespace/pods/$encoded_pod/ephemeralcontainers"
echo "Creating ephemeral container '$container_name' in Pod '$namespace/$pod'..."
kubectl replace --raw "$resource_path" --filename - <<< "$payload" >/dev/null

deadline=$((SECONDS + startup_timeout_seconds))
last_waiting_reason=
running=false
while ((SECONDS < deadline)); do
  pod_json=$(kubectl get pod "$pod" --namespace "$namespace" --output json)
  status=$(jq -c --arg name "$container_name" \
    '.status.ephemeralContainerStatuses[]? | select(.name == $name)' \
    <<< "$pod_json" | head -n 1)

  if [[ $(jq -r '.state.running != null' <<< "${status:-null}") == true ]]; then
    running=true
    break
  fi

  if [[ $(jq -r '.state.terminated != null' <<< "${status:-null}") == true ]]; then
    reason=$(jq -r '.state.terminated.reason // empty' <<< "$status")
    exit_code=$(jq -r '.state.terminated.exitCode // empty' <<< "$status")
    message=$(jq -r '.state.terminated.message // empty' <<< "$status")
    fail "Ephemeral container '$container_name' terminated before attachment (reason: $reason; exit code: $exit_code; message: $message)."
  fi

  waiting_reason=$(jq -r '.state.waiting.reason // empty' <<< "${status:-null}")
  if [[ -n $waiting_reason && $waiting_reason != "$last_waiting_reason" ]]; then
    last_waiting_reason=$waiting_reason
    echo "Waiting for '$container_name': $last_waiting_reason"
  fi
  sleep 1
done

[[ $running == true ]] ||
  fail "Timed out after $startup_timeout_seconds seconds waiting for ephemeral container '$container_name' to start."

read -r -d '' socket_bridge_script <<'EOF' || true
set -eu
shared_dir=$1
found=0

for process_dir in /proc/[0-9]*; do
  [ -r "$process_dir/environ" ] || continue

  target_tmp=/tmp
  tmp_entry=$({ tr '\000' '\n' < "$process_dir/environ"; } 2>/dev/null | grep -m 1 '^TMPDIR=' || true)
  if [ -n "$tmp_entry" ]; then
    target_tmp=${tmp_entry#TMPDIR=}
  fi

  case "$target_tmp" in
    /*) ;;
    *) target_tmp=/tmp ;;
  esac

  for socket in "$process_dir/root$target_tmp"/dotnet-diagnostic-*-socket; do
    [ -S "$socket" ] || continue

    name=${socket##*/}
    destination="$shared_dir/$name"

    if [ -L "$destination" ] && [ ! -e "$destination" ]; then
      rm -f "$destination"
    fi

    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
      ln -s "$socket" "$destination"
    fi

    if [ -S "$destination" ]; then
      found=1
    fi
  done
done

if [ "$found" -eq 0 ]; then
  echo "No accessible .NET default diagnostic sockets were found." >&2
  exit 42
fi

echo "$found"
EOF

echo "Preparing .NET diagnostic socket discovery..."
if kubectl exec "pod/$pod" \
  --namespace "$namespace" \
  --container "$container_name" \
  -- "$shell" -c "$socket_bridge_script" -- "$mount_path" >/dev/null; then
  echo "Prepared .NET diagnostic socket discovery."
elif [[ $skip_socket_discovery_validation == true ]]; then
  echo "Warning: Socket discovery could not be prepared." >&2
else
  fail "Ephemeral container '$container_name' is running, but .NET socket discovery could not be prepared. Ensure the target process has diagnostics enabled and runs as the same UID."
fi

exec_command=$(quote_command kubectl exec -it --namespace "$namespace" "pod/$pod" \
  --container "$container_name" -- "$shell")
process_command=$(quote_command kubectl exec --namespace "$namespace" "pod/$pod" \
  --container "$container_name" -- /tools/dotnet-trace ps)
copy_command=$(quote_command ./scripts/Copy-DotnetDiagArtifacts.sh \
  --pod "$pod" \
  --container-name "$container_name" \
  --namespace "$namespace" \
  --remote-path "$mount_path/app.nettrace" \
  --destination ./app.nettrace)

echo "Ephemeral container '$container_name' is running."
echo "Reconnect later with: $exec_command"
echo "List .NET processes with: $process_command"
echo "Copy and remove an artifact with: $copy_command"
echo "Add --terminate-container to terminate the primary shell after a successful copy and cleanup."

[[ $no_attach == true ]] && exit 0

echo "Attaching interactive session..."
kubectl attach "pod/$pod" \
  --namespace "$namespace" \
  --container "$container_name" \
  --stdin \
  --tty ||
  fail "kubectl attach failed. Reconnect with: $exec_command"
