# .NET Kubernetes Debug Containers

Minimal troubleshooting containers for .NET 10 applications running on Kubernetes.

## Purpose

This repository publishes two Azure Linux 3 based utility images for diagnosing .NET workloads that run in distroless, chiseled, or otherwise no-shell application containers.

- `diag`: diagnostics tools only
- `debug`: diagnostics tools plus `vsdbg` for VS Code attach scenarios

These images are intended for Kubernetes pods that run .NET 10 applications and need a separate container for dump, trace, counter, or debugger access.

## Images

- `ghcr.io/OWNER/REPO/diag:latest`
- `ghcr.io/OWNER/REPO/debug:latest`

## Target Use Case

- Kubernetes workloads
- .NET 10 applications
- Azure Linux 3 aligned tooling container images
- App images based on distroless, chiseled, or no-shell container patterns

## Recommended Pod Setup

Configure the application pod so the diagnostics container can observe and connect to the target .NET process.

- Set `shareProcessNamespace: true`
- Run the app container as UID `1654`
- Mount a shared `emptyDir` volume at `/diag`
- Optionally set `DOTNET_DiagnosticPorts=/diag/dotnet-diagnostic.sock,suspend=n,listen`

The sample manifest in `examples/kubernetes/pod-with-diag-volume.yaml` shows the recommended layout.

## Diag vs Debug

Use `diag` when you only need collection tools such as traces, dumps, counters, GC dumps, or stack snapshots.

Use `debug` when you need those same tools and also want to attach VS Code through `vsdbg`.

## Common Commands

Start an ephemeral diagnostics container:

```sh
kubectl debug pod/my-app -it --target app --image ghcr.io/OWNER/REPO/diag:latest --container dotnet-diag -- /bin/sh
```

List visible .NET processes:

```sh
kubectl exec -it my-app -c dotnet-diag -- dotnet-counters ps
```

Collect a trace through the shared diagnostic port:

```sh
kubectl exec -it my-app -c dotnet-diag -- dotnet-trace collect --diagnostic-port /diag/dotnet-diagnostic.sock --output /diag/app.nettrace
```

Collect a dump:

```sh
kubectl exec -it my-app -c dotnet-diag -- dotnet-dump collect --diagnostic-port /diag/dotnet-diagnostic.sock --output /diag/app.dmp
```

Collect a GC dump:

```sh
kubectl exec -it my-app -c dotnet-diag -- dotnet-gcdump collect --diagnostic-port /diag/dotnet-diagnostic.sock --output /diag/app.gcdump
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
