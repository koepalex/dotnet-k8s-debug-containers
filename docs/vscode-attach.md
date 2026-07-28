# VS Code Attach Guide

The `debug` image includes `vsdbg` so VS Code can attach through `kubectl exec` without requiring any shell or debugger tooling in the application container.

Start the ephemeral debug container with the same stable name used by
`launch.json`:

```pwsh
.\scripts\Start-DotnetDebugSession.ps1 `
  -Pod my-app `
  -TargetContainer app `
  -Namespace default `
  -ContainerName dotnet-debug `
  -NoAttach
```

The script creates the container atomically with the shared `/diag` volume
mount. `-NoAttach` leaves its shell running for VS Code; an ephemeral container
cannot be restarted after its shell exits.

The debug image sets `TMPDIR=/diag` for the bundled `dotnet-*` tools. `vsdbg`
itself attaches through the shared process namespace rather than selecting the
runtime through that diagnostic socket. The debug script requests
root execution, `SYS_PTRACE`, and an unconfined seccomp profile; the cluster's
Pod Security and AppArmor policies must permit those settings.

Copy this into `.vscode/launch.json` and adjust names as needed:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach to .NET in Kubernetes",
      "type": "coreclr",
      "request": "attach",
      "processId": "${command:pickRemoteProcess}",
      "pipeTransport": {
        "pipeProgram": "kubectl",
        "pipeArgs": [
          "exec",
          "-i",
          "my-app",
          "-c",
          "dotnet-debug",
          "--"
        ],
        "debuggerPath": "/vsdbg/vsdbg",
        "quoteArgs": false
      },
      "sourceFileMap": {
        "/app": "${workspaceFolder}"
      }
    }
  ]
}
```

## Notes

- Replace `my-app` with the target pod name
- Replace `dotnet-debug` if you use a different ephemeral container name
- If you use namespaces, add `-n` and the namespace to `pipeArgs`
- The caller needs create permission on the `pods/exec` subresource
- Keep the app sources mapped from `/app` to `${workspaceFolder}` so breakpoints resolve correctly
