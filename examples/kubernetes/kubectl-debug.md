# kubectl debug Examples

These examples assume the pod already follows the shared diagnostics volume pattern from `examples/kubernetes/pod-with-diag-volume.yaml`.

## Start A Diag Ephemeral Container

```sh
kubectl debug pod/my-app -it --target app --image ghcr.io/OWNER/REPO/diag:latest --container dotnet-diag -- /bin/sh
```

## Start A Debug Ephemeral Container

```sh
kubectl debug pod/my-app -it --target app --image ghcr.io/OWNER/REPO/debug:latest --container dotnet-debug -- /bin/sh
```

## Collect Artifacts

List visible .NET processes:

```sh
kubectl exec -it my-app -c dotnet-diag -- dotnet-counters ps
```

Collect counters from the shared diagnostic socket:

```sh
kubectl exec -it my-app -c dotnet-diag -- dotnet-counters monitor --diagnostic-port /diag/dotnet-diagnostic.sock System.Runtime
```

Collect a trace:

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

## Copy Artifacts Out Of The Pod

```sh
kubectl cp my-app:/diag/app.nettrace ./app.nettrace -c app
kubectl cp my-app:/diag/app.dmp ./app.dmp -c app
kubectl cp my-app:/diag/app.gcdump ./app.gcdump -c app
```
