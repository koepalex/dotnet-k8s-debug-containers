# Customer Guide

## Why This Exists

Many production .NET containers are intentionally minimal. They may be distroless, chiseled, or built without a shell and without troubleshooting tools. That keeps the app image small and reduces attack surface, but it also makes live investigation harder when a pod needs diagnostics.

This repository provides separate troubleshooting containers that can be attached to the pod instead of modifying the application image.

## Security Model

The application container stays focused on running the app.

- No shell is required in the app container
- The diagnostics or debugger tools run in a separate container
- Access is limited to what Kubernetes allows for that extra container and the pod it joins
- The shared `/diag` volume is only used for diagnostic sockets and collected artifacts

This design keeps operational tooling out of the main app image while still allowing controlled troubleshooting access.

## UID Recommendation

Run the troubleshooting container with the same UID as the application process when possible.

This repository uses UID `1654` and recommends that the .NET app container also runs as UID `1654`. Matching UIDs improves the chances that .NET diagnostics can connect successfully to the target process.

## No Shell In The App Container

The target app container does not need `/bin/sh`, package managers, or the .NET SDK.

The diagnostics container provides the tooling and interacts with the app process through shared pod namespaces and the shared diagnostics directory.

Set `TMPDIR=/diag` on the application container. The troubleshooting images use
the same value, allowing the standard `dotnet-*` tools to discover the
runtime's default Unix diagnostic socket without a per-command
`--diagnostic-port` argument.

## Debug Container Separation

The `debug` image is intentionally separate from the app container.

- `diag` is preferred for counters, traces, dumps, GC dumps, and stack inspection
- `debug` adds `vsdbg` for interactive attach from VS Code

Use `debug` only when interactive debugging is actually needed.

## Limitations

- Live breakpoint debugging can pause the application process
- Hardened seccomp or AppArmor profiles may block diagnostics or debugger operations
- Different UIDs between the target process and the troubleshooting container may prevent attachment
- Read-only filesystems still need a writable shared `/diag` volume for sockets and collected artifacts

## Production Recommendation

Prefer non-invasive collection in production.

- Use counters for quick health insight
- Use traces for performance investigations
- Use dumps or GC dumps for deeper offline analysis
- Avoid live breakpoints in production unless there is a strong operational reason

In most production cases, dump, trace, and counter collection are lower-risk than attaching a live debugger.
