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

Use the PowerShell helper to validate the Pod, create the fully configured
ephemeral container through the `ephemeralcontainers` subresource, and leave
its primary shell running:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -NoAttach
```

The helper generates a unique container name and prints the exact
`kubectl exec` command for entering it. Exiting that exec session does not stop
the ephemeral container, so collected artifacts remain available to
`kubectl cp`.

For a one-off session, omit `-NoAttach` to attach directly. The attached shell
is the container's primary process, so copy artifacts from another terminal
before exiting it. An ephemeral container cannot be restarted.

Use the corresponding helper when the session also needs `vsdbg`:

```pwsh
.\scripts\Start-DotnetDebugSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -ContainerName dotnet-debug `
  -NoAttach
```

An explicit container name is recommended for VS Code so `launch.json` can
reference a stable value. `-NoAttach` leaves the container's shell running while
VS Code uses `kubectl exec` to launch `/vsdbg/vsdbg`. The debug helper runs as
root and requests `SYS_PTRACE`; restricted Pod Security or AppArmor policies can
reject or block debugger attachment.

The script requires permission to read Pods, update
`pods/ephemeralcontainers`, and create `pods/exec` requests. Interactive
attachment additionally requires create permission on `pods/attach`; it is not
needed with `-NoAttach`. The script fails before creating the container when
the target container or Pod-level `emptyDir` volume is missing.
After startup it verifies that at least one accessible default .NET diagnostic
socket can be prepared.

Use `-WhatIf` to inspect the generated Pod payload without adding the
ephemeral container. Use `-NoAttach` to create and prepare the container without
opening an interactive shell.

The sample manifest in `examples/kubernetes/pod-with-diag-volume.yaml` shows the recommended static pod layout.

### Verified Sample Application

`examples/sample-app` contains the minimal .NET 10 target image used to verify
the diagnostics and debugger workflows:

```sh
docker build \
  -f examples/sample-app/Dockerfile \
  -t dotnet-k8s-sample:local \
  examples/sample-app
```

Publish that image to a registry accessible by the cluster and use it as the
`app` image in `examples/kubernetes/pod-with-diag-volume.yaml`.

## Diag vs Debug

Use `diag` when you only need collection tools such as traces, dumps, counters, GC dumps, or stack snapshots.

Use `debug` when you need those same tools and also want to attach VS Code
through `vsdbg`. `Start-DotnetDiagSession.ps1` defaults to the `diag` image;
`Start-DotnetDebugSession.ps1` defaults to the `debug` image.
The debug helper runs as root with `SYS_PTRACE` and an unconfined seccomp
profile so `vsdbg` can attach. Cluster security policy can reject those
settings.

## Common Commands

Start a reusable ephemeral diagnostics container:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -NoAttach
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

Copy artifacts to the local machine:

```sh
kubectl cp my-app:/diag/app.nettrace ./app.nettrace -c <generated-container-name>
```

When using direct attachment instead of `-NoAttach`, run `kubectl cp` from
another terminal before exiting the attached shell.

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
