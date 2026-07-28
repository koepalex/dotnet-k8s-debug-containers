# Ephemeral Diagnostics Examples

These examples assume the pod already follows the shared diagnostics volume pattern from `examples/kubernetes/pod-with-diag-volume.yaml`.

## Start A Diagnostics Session

`kubectl debug` does not inherit the target container's volume mounts, and an
ephemeral container cannot be patched after creation. Use the helper script to
create the container with the `/diag` mount atomically and attach to it:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default
```

The script defaults to
`ghcr.io/koepalex/dotnet-k8s-debug-containers/diag:latest`. Override `-Image`,
`-VolumeName`, `-MountPath`, or `-DiagnosticSocket` when the Pod uses different
values.

The published images and generated ephemeral containers set `TMPDIR` to the
shared mount path. The target application must set the same `TMPDIR` value so
the default .NET diagnostic socket is automatically discoverable.

If `TMPDIR` or the backward-compatible `DOTNET_DiagnosticPorts` setting is
supplied through `envFrom` or admission injection, bypass only that preflight
check:

```pwsh
.\scripts\Start-DotnetDiagSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -SkipSocketDiscoveryValidation
```

## Start A Debug Session

Use the debug helper when the ephemeral container also needs `vsdbg`. Set a
stable name when VS Code will reference the container from `launch.json`:

```pwsh
.\scripts\Start-DotnetDebugSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -ContainerName dotnet-debug
```

Keep the attached shell running while VS Code launches `/vsdbg/vsdbg` through
`kubectl exec`. The debug image also contains all diagnostic tools shown below.

## Collect Artifacts

The script prints the generated ephemeral-container name before attachment.
With a shared `TMPDIR`, the tools discover the runtime's default socket
automatically.

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
kubectl cp my-app:/diag/app.nettrace ./app.nettrace -c app
kubectl cp my-app:/diag/app.dmp ./app.dmp -c app
kubectl cp my-app:/diag/app.gcdump ./app.gcdump -c app
```
