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

Configure the application pod so `kubectl debug` can attach an ephemeral diagnostics container with access to the target .NET process.

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
- Set `DOTNET_DiagnosticPorts=/diag/dotnet-diagnostic.sock,suspend=n,listen` on the app container

### Ephemeral Container with Volume Mount

Use `kubectl debug` with a JSON patch to attach a diagnostics container that shares the pod's `/diag` volume. This avoids modifying the deployment:

```sh
kubectl debug pod/my-app \
  --target app \
  --image ghcr.io/koepalex/dotnet-k8s-debug-containers/diag:latest \
  -it \
  -- /bin/sh
```

If the debug container cannot access the `/diag` volume (e.g., socket not found), manually patch the ephemeral container's volumeMounts and ensure the pod spec declares the volume. Kubernetes may auto-inject the volume, but if not:

```sh
kubectl patch pod my-app \
  --type='json' \
  -p='[
    {
      "op": "add",
      "path": "/spec/ephemeralContainers/0/volumeMounts",
      "value": [{"name": "diagnostics", "mountPath": "/diag"}]
    }
  ]'
```

The sample manifest in `examples/kubernetes/pod-with-diag-volume.yaml` shows the recommended static pod layout.

## Diag vs Debug

Use `diag` when you only need collection tools such as traces, dumps, counters, GC dumps, or stack snapshots.

Use `debug` when you need those same tools and also want to attach VS Code through `vsdbg`.

## Common Commands

Start an ephemeral diagnostics container:

```sh
kubectl debug pod/my-app \
  --target app \
  --image ghcr.io/koepalex/dotnet-k8s-debug-containers/diag:latest \
  -it \
  -- /bin/sh
```

If the container starts but cannot see the diagnostic socket, the ephemeral container may not have inherited the pod's `diagnostics` volume. Verify the pod spec includes `volumes.name: diagnostics` and patch the ephemeral container as shown in [Recommended Pod Setup](#recommended-pod-setup).

List visible .NET processes:

```sh
dotnet-trace ps
```

Or via `kubectl exec` on the ephemeral container:

```sh
kubectl exec -it my-app -c debugger -- dotnet-trace ps
```

Collect a trace through the shared diagnostic port:

```sh
dotnet-trace collect --diagnostic-port /diag/dotnet-diagnostic.sock --output /diag/app.nettrace
```

Collect a dump:

```sh
dotnet-dump collect --diagnostic-port /diag/dotnet-diagnostic.sock --output /diag/app.dmp
```

Collect a GC dump:

```sh
dotnet-gcdump collect --diagnostic-port /diag/dotnet-diagnostic.sock --output /diag/app.gcdump
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
