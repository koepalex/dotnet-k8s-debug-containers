# Ephemeral Diagnostics Examples

These examples assume the Pod declares the tooling-only diagnostics volume
shown in `examples/kubernetes/pod-with-diag-volume.yaml`.

## Start A Diagnostics Session

`kubectl debug` does not add Pod volume mounts to an ephemeral container, and
an ephemeral container cannot be patched after creation. Use the helper script
to create the container with the `/diag` mount atomically and leave its primary
shell running:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -NoAttach
```

The script defaults to
`ghcr.io/koepalex/dotnet-k8s-debug-containers/diag:latest`. Override `-Image`,
`-VolumeName`, or `-MountPath` when the Pod uses different values.

After the container starts, the script finds the target runtime's default
socket through `/proc`, exposes it under `/diag`, and prints the generated
container name and exact `kubectl exec` command for entering the session.
Exiting that exec session leaves the ephemeral container running so artifacts
can still be copied.

To attach directly for a one-off session, omit `-NoAttach`:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default
```

The attached shell is the container's primary process. Copy artifacts from
another terminal before exiting it because an ephemeral container cannot be
restarted. Do not reuse an explicit diagnostics container name for later
sessions; omitting `-ContainerName` generates a unique name each time.

An ephemeral container cannot be changed or removed after it is added to the
Pod. Terminating its primary shell releases the running process resources, but
the terminated, non-restartable container record remains until the Pod is
deleted or replaced.

The sample diagnostics `emptyDir: {}` uses node ephemeral storage, not RAM, and
its files survive container termination. The files remain until they are
explicitly deleted or the Pod is removed from the node. An `emptyDir` is
RAM-backed only when it declares `medium: Memory`.

## Start A Debug Session

Use the debug helper when the ephemeral container also needs `vsdbg`. Set a
stable name when VS Code will reference the container from `launch.json`:

```pwsh
.\scripts\Start-DotnetDebugSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -ContainerName dotnet-debug `
  -NoAttach
```

`-NoAttach` leaves the container shell running while VS Code launches
`/vsdbg/vsdbg` through `kubectl exec`. The debug image also contains all
diagnostic tools shown below. It runs as root and requests `SYS_PTRACE` with an
unconfined seccomp profile; cluster security policy must allow these settings.

## Collect Artifacts

The script prints the generated ephemeral-container name before attachment.
The session script prepares the target's default socket so the tools can
discover it automatically.

List .NET processes:

```sh
dotnet-trace ps
```

Collect counters:

```sh
dotnet-counters monitor --process-id <pid> System.Runtime
```

Collect a trace:

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

## Copy Artifacts Out Of The Pod

Copy one explicit file or directory and remove only that remote path after the
copy succeeds:

```pwsh
.\scripts\Copy-DotnetDiagArtifacts.ps1 `
  -Pod my-app `
  -ContainerName <generated-container-name> `
  -Namespace default `
  -RemotePath /diag/app.nettrace `
  -Destination .\app.nettrace
```

The destination must not already exist. The helper rejects `/diag` itself,
paths outside the configured mount, and path traversal. It leaves unrelated
socket links, debugger files, and artifacts untouched. Use `-MountPath` when
the Pod uses a different diagnostics mount and `-WhatIf` to preview the
operation.

To copy and remove an artifact directory:

```pwsh
.\scripts\Copy-DotnetDiagArtifacts.ps1 `
  -Pod my-app `
  -ContainerName <generated-container-name> `
  -RemotePath /diag/investigation-2026-08-11 `
  -Destination .\investigation-2026-08-11
```

Add `-TerminateContainer` to exit the primary shell after the copy and cleanup
finish. The container then releases its running process resources and cannot
restart, while its immutable Pod record remains. Use the container name printed
by the session helper. With direct attachment, run the copy helper from another
terminal before exiting the attached shell.
