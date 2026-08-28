# .NET Kubernetes Debug Containers

Minimal troubleshooting containers for .NET 10 applications running on Kubernetes.

## Purpose

This repository publishes two Azure Linux 3 based utility images for diagnosing .NET workloads that run in distroless, chiseled, or otherwise no-shell application containers.

- `diag`: diagnostics tools only
- `debug`: diagnostics tools plus `vsdbg` for VS Code attach scenarios

These images are intended for Kubernetes pods that run .NET 10 applications and need a separate container for dump, trace, counter, or debugger access.

## Images

- `ghcr.io/koepalex/dotnet-k8s-debug-containers/diag:latest`
- `ghcr.io/koepalex/dotnet-k8s-debug-containers/debug:latest`

## Target Use Case

- Kubernetes workloads
- .NET 10 applications
- Azure Linux 3 aligned tooling container images
- App images based on distroless, chiseled, or no-shell container patterns

## Recommended Pod Setup

Configure the application pod so an ephemeral diagnostics container can access the target .NET process.

### Prerequisites

- Set `shareProcessNamespace: true`.
- Run the app as UID `1654`, matching the `diag` image.
- Set Pod `fsGroup: 1654`.
- Declare a writable `emptyDir` volume named `diagnostics`.
- Leave .NET diagnostics enabled (the runtime default).

The session scripts locate the target runtime's default diagnostic sockets
through the shared process namespace and expose them under `/diag`, allowing
the standard `dotnet-*` tools to discover the target automatically. The
diagnostics volume is mounted only into the ephemeral container; the
application container does not mount `/diag`.

### Start an Ephemeral Diagnostics Session

`kubectl debug` does not add Pod volume mounts to an ephemeral container. The
helper creates the container with the diagnostics volume mount already present;
Kubernetes does not allow adding it after creation.

Use the PowerShell or Bash helper to validate the Pod, create the fully
configured ephemeral container through the `ephemeralcontainers` subresource,
and leave its primary shell running:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -NoAttach
```

```sh
./scripts/Start-DotnetDiagSession.sh \
  --pod my-app \
  --target-container app \
  --namespace default \
  --no-attach
```

The helper generates a unique container name and prints the exact
`kubectl exec` command for entering it. Exiting that exec session does not stop
the ephemeral container, so collected artifacts remain available to
`kubectl cp`.

For a one-off session, omit `-NoAttach` or `--no-attach` to attach directly.
The attached shell is the container's primary process, so copy artifacts from
another terminal before exiting it. An ephemeral container cannot be restarted.

<mark>Kubernetes does not allow an ephemeral container to be changed or removed after
it is added. Its Pod API entry remains until the Pod is deleted or replaced.
The container process can terminate, however; after termination it no longer
uses process memory or CPU, but it cannot be started again.</mark>

The diagnostics volume has a separate lifecycle. The sample uses
`emptyDir: {}`, which is backed by node ephemeral storage rather than RAM and
keeps its files across container termination. Its contents are deleted when the
Pod is removed from the node, or they can be deleted explicitly after copying.
Only an `emptyDir` configured with `medium: Memory` is RAM-backed.

Use the corresponding helper when the session also needs `vsdbg`:

```pwsh
.\scripts\Start-DotnetDebugSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -ContainerName dotnet-debug `
  -NoAttach
```

```sh
./scripts/Start-DotnetDebugSession.sh \
  --pod my-app \
  --target-container app \
  --namespace default \
  --container-name dotnet-debug \
  --no-attach
```

An explicit container name is recommended for VS Code so `launch.json` can
reference a stable value. `-NoAttach` or `--no-attach` leaves the container's
shell running while VS Code uses `kubectl exec` to launch `/vsdbg/vsdbg`. The
debug helper runs as root and requests `SYS_PTRACE`; restricted Pod Security or
AppArmor policies can reject or block debugger attachment.

The session helpers require permission to read Pods, update
`pods/ephemeralcontainers`, and create `pods/exec` requests. Interactive
attachment additionally requires create permission on `pods/attach`; it is not
needed with `-NoAttach` or `--no-attach`. The helpers fail before creating the
container when the target container or Pod-level `emptyDir` volume is missing.
After startup it verifies that at least one accessible default .NET diagnostic
socket can be prepared.

The PowerShell and Bash `Copy-DotnetDiagArtifacts` helpers require Pod read and
exec permissions. Their optional termination switch also requires attach
permission because it exits the primary shell and confirms that the container
reached a terminated state.

Use `-WhatIf` in PowerShell or `--what-if` in Bash to inspect the generated Pod
payload without adding the ephemeral container. Use `-NoAttach` or
`--no-attach` to create and prepare the container without opening an
interactive shell. The Bash helpers require Bash 4+, `kubectl`, and `jq`.

The sample manifest in `examples/kubernetes/pod-with-diag-volume.yaml` shows the recommended static pod layout.

### Verified Sample Application

`examples/sample-app` contains the minimal .NET 10 target image used to verify
the diagnostics and debugger workflows:

```pwsh
$env:SOURCE_REVISION_ID = git rev-parse HEAD
docker buildx bake `
  --file .\examples\sample-app\docker-bake.hcl
```

The Bake definition loads `dotnet-k8s-sample:local` and exports the exact
portable PDB produced with its Release DLL to
`artifacts/sample-app/symbols`. The final runtime image does not contain the
PDB.

Publish that image to a registry accessible by the cluster and use it as the
`app` image in `examples/kubernetes/pod-with-diag-volume.yaml`.

For VS Code attach, archive the original PDB from the application build, tie it
to the immutable application image digest, and keep the exact source commit
available locally. The sample workflow publishes downloadable symbol bundles
for this purpose. See `docs/vscode-attach.md` for the complete Release-symbol
workflow.

## Diag vs Debug

Use `diag` when you only need collection tools such as traces, dumps, counters, GC dumps, or stack snapshots.

Use `debug` when you need those same tools and also want to attach VS Code
through `vsdbg`. Both `Start-DotnetDiagSession` scripts default to the `diag`
image; both `Start-DotnetDebugSession` scripts default to the `debug` image.
The debug helper runs as root with `SYS_PTRACE` and an unconfined seccomp
profile so `vsdbg` can attach. Cluster security policy can reject those
settings. The application must separately preserve the exact portable PDBs
produced with the deployed Release binaries; the debugger rejects mismatched
symbols. The debug image starts `vsdbg` through `/vsdbg/run-vsdbg`, which maps
the debugger IPC temp directory into the target container's filesystem through
`/proc`.

## Common Commands

Start a reusable ephemeral diagnostics container:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -NoAttach
```

```sh
./scripts/Start-DotnetDiagSession.sh \
  --pod my-app \
  --target-container app \
  --namespace default \
  --no-attach
```

Use the generated container name and reconnect command printed by the helper.
Omitting `-ContainerName` allows repeated sessions against the same Pod because
each ephemeral container receives a unique name.

Start a VS Code-capable debug container with a stable name:

```pwsh
.\scripts\Start-DotnetDebugSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -ContainerName dotnet-debug `
  -NoAttach
```

```sh
./scripts/Start-DotnetDebugSession.sh \
  --pod my-app \
  --target-container app \
  --namespace default \
  --container-name dotnet-debug \
  --no-attach
```

List automatically discoverable .NET processes:

```sh
dotnet-trace ps
```

Collect a trace using the discovered process ID:

```sh
dotnet-trace collect --process-id <pid> --output /diag/app.nettrace
```

Collect a dump:

```sh
dotnet-dump collect --process-id <pid> --output /diag/app.dmp
```

Collect a GC dump:

```sh
dotnet-gcdump collect --process-id <pid> --output /diag/app.gcdump
```

### Create And Download A Dump In Unattached Mode

Start the diagnostics container with `--no-attach`. The helper prints the
generated container name and a reconnect command. Use that name in the
following commands:

```sh
# List the target .NET processes without opening an interactive shell.
kubectl exec \
  --namespace default \
  pod/my-app \
  --container <generated-container-name> \
  -- /tools/dotnet-trace ps

# Create the dump in the diagnostics volume.
kubectl exec \
  --namespace default \
  pod/my-app \
  --container <generated-container-name> \
  -- /tools/dotnet-dump collect \
     --process-id <pid> \
     --output /diag/app.dmp

# Copy the dump to the current Linux machine and remove the remote file.
./scripts/Copy-DotnetDiagArtifacts.sh \
  --pod my-app \
  --container-name <generated-container-name> \
  --namespace default \
  --remote-path /diag/app.dmp \
  --destination ./app.dmp
```

The copy helper verifies that `./app.dmp` was created before deleting
`/diag/app.dmp`. The destination must not already exist. Add
`--terminate-container` when the diagnostics session is no longer needed.

Copy an artifact to the local machine and remove only that exact remote path
after the copy succeeds:

```pwsh
.\scripts\Copy-DotnetDiagArtifacts.ps1 `
  -Pod my-app `
  -ContainerName <generated-container-name> `
  -Namespace default `
  -RemotePath /diag/app.nettrace `
  -Destination .\app.nettrace
```

```sh
./scripts/Copy-DotnetDiagArtifacts.sh \
  --pod my-app \
  --container-name <generated-container-name> \
  --namespace default \
  --remote-path /diag/app.nettrace \
  --destination ./app.nettrace
```

The destination must not already exist. The helper rejects the diagnostics
mount root and paths outside it, and it does not delete the remote file unless
`kubectl cp` succeeds and creates the local destination. Use `-WhatIf` or
`--what-if` to preview the operation.

Add `-TerminateContainer` or `--terminate-container` to terminate the primary
shell after successful copy and cleanup. This releases the running process
resources but does not remove the immutable ephemeral-container record from the
Pod. When using direct attachment instead of `-NoAttach` or `--no-attach`, run
the helper from another terminal before exiting the attached shell.

More command examples are in `examples/kubernetes/kubectl-debug.md`.

## Documentation

- `docs/customer-guide.md`
- `docs/vscode-attach.md`
- `examples/kubernetes/pod-with-diag-volume.yaml`
- `examples/kubernetes/kubectl-debug.md`

## Local Build

Build both images locally:

```sh
./scripts/local-build.sh
```

## License

MIT
