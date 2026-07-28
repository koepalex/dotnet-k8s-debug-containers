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

- Set `shareProcessNamespace: true` on the pod
  - If deploying after pod creation, this causes a rolling restart:
  ```pwsh
  kubectl patch deployment mypod `
    -n mynamespace `
    --type='strategic' `
    -p='{"spec":{"template":{"spec":{"shareProcessNamespace":true}}}}
  ```
- Run the app container as UID `1654` (matches the diagnostics container user)
- Mount a shared `emptyDir` volume at `/diag` in the app container
- Set `TMPDIR=/diag` on the app container

Both published troubleshooting images already set `TMPDIR=/diag`. When the app
container uses the same value and shares the volume, the runtime's default
diagnostic socket is created under `/diag` and the `dotnet-*` tools can discover
it automatically. Setting the variable only on the troubleshooting image is
not sufficient; the target .NET runtime must use it too.

### Start an Ephemeral Diagnostics Session

`kubectl debug` does not copy volume mounts from the target container. The
ephemeral container must therefore be created with the diagnostics volume mount
already present; Kubernetes does not allow adding it after creation.

Use the PowerShell helper to validate the Pod, create the fully configured
ephemeral container through the `ephemeralcontainers` subresource, wait for it,
and attach an interactive shell:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default
```

Use the corresponding helper when the session also needs `vsdbg`:

```pwsh
.\scripts\Start-DotnetDebugSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -ContainerName dotnet-debug
```

An explicit container name is recommended for VS Code so `launch.json` can
reference a stable value. Keep the attached shell running while VS Code uses
`kubectl exec` to launch `/vsdbg/vsdbg`. The debug helper requests the
`SYS_PTRACE` capability; restricted Pod Security, seccomp, or AppArmor policies
can reject or block debugger attachment.

The script requires permission to read Pods, update
`pods/ephemeralcontainers`, and create `pods/attach` requests. Reconnecting with
the printed `kubectl exec` command also requires create permission on
`pods/exec`. It fails before creating the container when the target container,
shared `emptyDir` volume, volume mount, or direct
`TMPDIR` socket-discovery configuration is missing. Existing workloads using
`DOTNET_DiagnosticPorts=/diag/dotnet-diagnostic.sock,connect,nosuspend` remain
supported. If configuration is supplied indirectly through `envFrom` or
admission injection, use `-SkipSocketDiscoveryValidation`.

Use `-WhatIf` to inspect the generated Pod payload without adding the
ephemeral container.

The sample manifest in `examples/kubernetes/pod-with-diag-volume.yaml` shows the recommended static pod layout.

## Diag vs Debug

Use `diag` when you only need collection tools such as traces, dumps, counters, GC dumps, or stack snapshots.

Use `debug` when you need those same tools and also want to attach VS Code
through `vsdbg`. `Start-DotnetDiagSession.ps1` defaults to the `diag` image;
`Start-DotnetDebugSession.ps1` defaults to the `debug` image.

## Common Commands

Start and attach an ephemeral diagnostics container:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default
```

Start a VS Code-capable debug container with a stable name:

```pwsh
.\scripts\Start-DotnetDebugSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -ContainerName dotnet-debug
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
kubectl cp my-app:/diag/app.nettrace ./app.nettrace -c app
```

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
