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

```sh
kubectl cp my-app:/diag/app.nettrace ./app.nettrace -c <generated-container-name>
kubectl cp my-app:/diag/app.dmp ./app.dmp -c <generated-container-name>
kubectl cp my-app:/diag/app.gcdump ./app.gcdump -c <generated-container-name>
```

Use the container name printed by the helper. With direct attachment, run these
commands from another terminal before exiting the attached shell.
