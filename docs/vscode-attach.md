# VS Code Attach Guide

The `debug` image includes `vsdbg` so VS Code can attach through `kubectl exec`
without requiring a shell or debugger tooling in the application container.

## Application Build Requirements

The debugger needs the exact PDB produced with the DLL that is running in the
Pod. Rebuilding the same commit later is not a supported substitute: the
debugger validates the PDB identity embedded in the module.

For a Release build, the application should:

- generate portable PDBs;
- keep compiler and JIT optimization enabled unless a different production
  tradeoff is intentional;
- use deterministic CI build settings;
- normalize compiler source paths to a stable root;
- archive the original PDBs separately from the runtime image;
- record the source commit and immutable application image digest with the
  symbols.

Modern .NET SDKs generate portable PDBs for Debug and Release by default. The
sample application configures this explicitly in
`examples/sample-app/SampleApp.csproj` and maps compiler source paths to
`/_/src`.

The sample Docker build has separate `runtime` and `symbols` targets that share
one publish stage. The final runtime image contains no application PDBs.

Build both outputs locally from the repository root:

```pwsh
$env:SOURCE_REVISION_ID = git rev-parse HEAD
docker buildx bake `
  --file .\examples\sample-app\docker-bake.hcl
```

This loads `dotnet-k8s-sample:local` and exports the matching PDB to
`artifacts/sample-app/symbols`.

## Download A Published Symbol Bundle

`.github/workflows/sample-app.yml` publishes a symbol bundle for each build.
The ZIP contains the portable PDB and `symbols-manifest.json`. The manifest
records the commit SHA, source root, application module, image reference, image
digest, and PDB hashes.

For a workflow build, find and download the artifact:

```pwsh
$commit = '<full-commit-sha>'
$runId = gh run list `
  --workflow sample-app.yml `
  --commit $commit `
  --json databaseId `
  --jq '.[0].databaseId'

$shortCommit = $commit.Substring(0, 12)
gh run download $runId `
  --name "sample-app-symbols-$shortCommit" `
  --dir .\artifacts\downloaded-symbols
```

Version tags also publish a durable GitHub Release asset:

```pwsh
gh release download v1.0.0 `
  --pattern 'sample-app-symbols-v1.0.0.zip' `
  --dir .\artifacts\downloaded-symbols
```

Extract the bundle and load its manifest:

```pwsh
$bundle = Get-ChildItem .\artifacts\downloaded-symbols\*.zip |
  Select-Object -First 1
$symbolsDirectory = '.\artifacts\downloaded-symbols\extracted'

Expand-Archive $bundle.FullName -DestinationPath $symbolsDirectory -Force
$manifest = Get-Content "$symbolsDirectory\symbols-manifest.json" |
  ConvertFrom-Json

foreach ($pdb in $manifest.pdbs) {
  $actualHash = (Get-FileHash `
    "$symbolsDirectory\$($pdb.fileName)" `
    -Algorithm SHA256).Hash.ToLowerInvariant()

  if ($actualHash -ne $pdb.sha256) {
    throw "Symbol hash validation failed for '$($pdb.fileName)'."
  }
}
```

Check out the exact source revision:

```pwsh
git fetch origin $manifest.commitSha
git switch --detach $manifest.commitSha
```

Compare the deployed application image with the immutable digest in the
manifest:

```pwsh
$deployedImageId = kubectl get pod my-app `
  --namespace default `
  --output 'jsonpath={.status.containerStatuses[?(@.name=="app")].imageID}'

if (-not $deployedImageId.Contains($manifest.imageDigest)) {
  throw "The symbol bundle does not match the deployed application image."
}
```

Do not continue when the digests differ. Download the bundle produced for the
deployed image instead.

## Start The Debug Container

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

The script creates the container atomically with the Pod's diagnostics volume
mounted at `/diag`. `-NoAttach` leaves its primary shell running for VS Code; an
ephemeral container cannot be restarted after that shell exits.

`vsdbg` attaches through the shared process namespace. The debug script
requests root execution, `SYS_PTRACE`, and an unconfined seccomp profile; the
cluster's Pod Security and AppArmor policies must permit those settings.
The image's `/vsdbg/run-vsdbg` wrapper also discovers the target process's
actual temp directory through `/proc`. This is required because the application
and ephemeral containers have different root filesystems, while the runtime
debugger IPC endpoint is created in the application's temp directory.

## Copy Symbols To Remote `vsdbg`

With `pipeTransport`, the debugger backend runs inside the ephemeral debug
container. Its symbol search directory must therefore exist in that container;
the PDB cannot remain only on the workstation.

Create the directory and copy the extracted bundle:

```pwsh
kubectl exec pod/my-app `
  --namespace default `
  --container dotnet-debug `
  -- mkdir -p /diag/symbols

kubectl cp `
  .\artifacts\downloaded-symbols\extracted\. `
  default/my-app:/diag/symbols `
  --container dotnet-debug
```

The source files remain local in VS Code. Only the PDB and manifest need to be
copied into the debug container.

## Configure VS Code

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
      "justMyCode": false,
      "requireExactSource": true,
      "pipeTransport": {
        "pipeProgram": "kubectl",
        "pipeArgs": [
          "exec",
          "-i",
          "--namespace",
          "default",
          "pod/my-app",
          "--container",
          "dotnet-debug",
          "--"
        ],
        "debuggerPath": "/vsdbg/run-vsdbg",
        "quoteArgs": false
      },
      "symbolOptions": {
        "searchPaths": [
          "/diag/symbols"
        ],
        "moduleFilter": {
          "mode": "loadOnlyIncluded",
          "includedModules": [
            "SampleApp.dll"
          ],
          "includeSymbolsNextToModules": false
        }
      },
      "sourceFileMap": {
        "/_/src": "${workspaceFolder}/examples/sample-app"
      },
      "sourceLinkOptions": {
        "https://raw.githubusercontent.com/*": {
          "enabled": true
        },
        "*": {
          "enabled": false
        }
      },
      "logging": {
        "moduleLoad": true
      }
    }
  ]
}
```

`sourceFileMap` maps the compiler path stored in the PDB, not the runtime module
path `/app`. If the application repository itself is the VS Code workspace,
map `/_/src` directly to `${workspaceFolder}`.

Source Link is enabled only as a fallback for public GitHub source. For private
applications, use an authorized local checkout of the manifest's exact commit.

## Debugging Release Builds

A matching portable PDB allows VS Code to resolve methods and source lines in a
Release assembly. It does not make optimized code behave like a Debug build.
`justMyCode` is disabled in the example because the debugger otherwise skips
symbol loading for the optimized application module.

Expect these limitations:

- stepping can skip or reorder source statements;
- local variables can be optimized away;
- a breakpoint can move to the nearest executable sequence point;
- inlined methods may not appear as separate frames.

VS Code's `suppressJITOptimizations` option cannot retroactively change modules
that were already loaded when the debugger attached. Live attach to a running
production process should therefore be treated as optimized debugging.

ReadyToRun, trimming, single-file publishing, and Native AOT can impose
additional limitations. Validate the exact publish mode used by the
application. Native AOT does not use the normal managed `coreclr` attach flow.

## Symbol Bundles And Symbol Servers

Symbol servers remain a current and scalable solution, especially for shared
libraries and organizations that retain many builds. NuGet `.snupkg` packages
and the NuGet.org symbol server are the normal choice for libraries distributed
as NuGet packages.

For an application container, a versioned bundle is often simpler because the
image is the deployment unit. The bundle maps directly to an image digest. The
same portable PDBs can later be published to a symbol server; VS Code accepts
symbol-server URLs in `symbolOptions.searchPaths`.

## Troubleshooting

- Replace `my-app`, `app`, and `dotnet-debug` with the deployed names.
- If the debugger reports that symbols were not loaded, inspect module-load
  messages in the Debug Console and verify `/diag/symbols`.
- If attach times out before modules load, verify that .NET diagnostics are
  enabled and that `/vsdbg/run-vsdbg` can discover the target process's
  diagnostic socket. In a Pod with multiple .NET containers, write the selected
  process path, such as `/proc/<pid>/root/tmp`, to
  `/diag/vsdbg-target-tmpdir` before attaching.
- If symbols are found but source does not open, verify the exact Git commit and
  the `sourceFileMap` compiler path.
- Never disable exact source matching to hide an image, PDB, or source-version
  mismatch.
- The caller needs create permission on the `pods/exec` subresource.
- Keep the application source mapped from `/_/src` so breakpoints resolve
  against the paths stored in the portable PDB.
