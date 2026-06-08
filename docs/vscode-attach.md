# VS Code Attach Guide

The `debug` image includes `vsdbg` so VS Code can attach through `kubectl exec` without requiring any shell or debugger tooling in the application container.

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
- Keep the app sources mapped from `/app` to `${workspaceFolder}` so breakpoints resolve correctly
