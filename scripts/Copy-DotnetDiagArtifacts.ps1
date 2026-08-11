[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Pod,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ContainerName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RemotePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Destination,

    [ValidateNotNullOrEmpty()]
    [string]$Namespace = 'default',

    [ValidateNotNullOrEmpty()]
    [string]$MountPath = '/diag',

    [ValidateNotNullOrEmpty()]
    [string]$Shell = '/bin/sh',

    [ValidateRange(1, 600)]
    [int]$TerminationTimeoutSeconds = 60,

    [switch]$TerminateContainer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Kubectl {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & kubectl @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return ($output -join [Environment]::NewLine)
}

function Get-Pod {
    $json = Invoke-Kubectl -Arguments @(
        'get',
        'pod',
        $Pod,
        '--namespace',
        $Namespace,
        '--output',
        'json'
    )

    return $json | ConvertFrom-Json
}

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-NormalizedContainerPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    if (-not $Path.StartsWith('/')) {
        throw "$ParameterName must be an absolute Linux container path."
    }

    $segments = [Collections.Generic.List[string]]::new()
    foreach ($segment in ($Path -split '/')) {
        if (-not $segment -or $segment -eq '.') {
            continue
        }

        if ($segment -eq '..') {
            if ($segments.Count -eq 0) {
                throw "$ParameterName cannot traverse above the container root."
            }

            $segments.RemoveAt($segments.Count - 1)
            continue
        }

        $segments.Add($segment)
    }

    return "/$($segments -join '/')"
}

function Get-EphemeralContainerStatus {
    param(
        [Parameter(Mandatory)]
        [object]$PodObject
    )

    $statuses = @(Get-PropertyValue -InputObject $PodObject.status -Name 'ephemeralContainerStatuses' | Where-Object {
            $null -ne $_
        })

    return @($statuses | Where-Object { $_.name -eq $ContainerName }) | Select-Object -First 1
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl was not found on PATH.'
}

$MountPath = ConvertTo-NormalizedContainerPath -Path $MountPath -ParameterName 'MountPath'
$RemotePath = ConvertTo-NormalizedContainerPath -Path $RemotePath -ParameterName 'RemotePath'

if ($MountPath -eq '/') {
    throw 'MountPath cannot be the container root.'
}

if ($RemotePath -eq $MountPath -or -not $RemotePath.StartsWith("$MountPath/", [StringComparison]::Ordinal)) {
    throw "RemotePath must identify a file or directory below MountPath '$MountPath'; the mount root itself cannot be copied and deleted."
}

if (Test-Path -LiteralPath $Destination) {
    throw "Destination '$Destination' already exists. Choose a new path so the copied result can be verified before remote cleanup."
}

$destinationParent = Split-Path -Parent $Destination
if (-not $destinationParent) {
    $destinationParent = '.'
}

if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    throw "Destination parent directory '$destinationParent' does not exist."
}

$podObject = Get-Pod
if (Get-PropertyValue -InputObject $podObject.metadata -Name 'deletionTimestamp') {
    throw "Pod '$Namespace/$Pod' is terminating."
}

$ephemeralContainers = @(Get-PropertyValue -InputObject $podObject.spec -Name 'ephemeralContainers' | Where-Object {
        $null -ne $_
    })
$ephemeralContainer = @($ephemeralContainers | Where-Object { $_.name -eq $ContainerName })
if ($ephemeralContainer.Count -ne 1) {
    throw "Ephemeral container '$ContainerName' was not found in Pod '$Namespace/$Pod'."
}

$containerStatus = Get-EphemeralContainerStatus -PodObject $podObject
$containerState = Get-PropertyValue -InputObject $containerStatus -Name 'state'
if (-not (Get-PropertyValue -InputObject $containerState -Name 'running')) {
    throw "Ephemeral container '$ContainerName' is not running. Files in its root filesystem are unavailable, and this Pod mounts the diagnostics volume only in that container."
}

$pathCheckScript = @'
set -eu
path=$1
[ -e "$path" ] || [ -L "$path" ]
'@
$pathCheckScript = $pathCheckScript.Replace("`r`n", "`n")
Invoke-Kubectl -Arguments @(
    'exec',
    "pod/$Pod",
    '--namespace',
    $Namespace,
    '--container',
    $ContainerName,
    '--',
    $Shell,
    '-c',
    $pathCheckScript,
    '--',
    $RemotePath
) | Out-Null

$action = "Copy '$RemotePath' to '$Destination', delete the exact remote path"
if ($TerminateContainer) {
    $action += ", and terminate ephemeral container '$ContainerName'"
}

if (-not $PSCmdlet.ShouldProcess("$Namespace/$Pod", $action)) {
    return
}

Write-Host "Copying '$Namespace/$Pod`:$RemotePath' to '$Destination'..."
Invoke-Kubectl -Arguments @(
    'cp',
    "$Namespace/$Pod`:$RemotePath",
    $Destination,
    '--container',
    $ContainerName
) | Out-Null

if (-not (Test-Path -LiteralPath $Destination)) {
    throw "kubectl cp completed, but destination '$Destination' was not created. The remote artifact was not deleted."
}

$removeScript = @'
set -eu
path=$1

if [ ! -e "$path" ] && [ ! -L "$path" ]; then
  echo "Remote path no longer exists: $path" >&2
  exit 44
fi

rm -rf -- "$path"

if [ -e "$path" ] || [ -L "$path" ]; then
  echo "Remote path still exists after deletion: $path" >&2
  exit 45
fi
'@
$removeScript = $removeScript.Replace("`r`n", "`n")

Write-Host "Removing exact remote path '$RemotePath'..."
Invoke-Kubectl -Arguments @(
    'exec',
    "pod/$Pod",
    '--namespace',
    $Namespace,
    '--container',
    $ContainerName,
    '--',
    $Shell,
    '-c',
    $removeScript,
    '--',
    $RemotePath
) | Out-Null

Write-Host "Copied artifact to '$Destination' and removed '$RemotePath'."

if (-not $TerminateContainer) {
    return
}

Write-Host "Requesting termination of ephemeral container '$ContainerName'..."
$attachOutput = "exit`n" | & kubectl attach "pod/$Pod" `
    --namespace $Namespace `
    --container $ContainerName `
    --stdin 2>&1
$attachExitCode = $LASTEXITCODE

# The attach transport can close with a nonzero exit when the primary shell
# exits, so the Pod status is the authoritative termination result.
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$terminatedState = $null
while ($stopwatch.Elapsed.TotalSeconds -lt $TerminationTimeoutSeconds) {
    $podObject = Get-Pod
    $containerStatus = Get-EphemeralContainerStatus -PodObject $podObject
    $containerState = Get-PropertyValue -InputObject $containerStatus -Name 'state'
    $terminatedState = Get-PropertyValue -InputObject $containerState -Name 'terminated'
    if ($terminatedState) {
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $terminatedState) {
    $attachDetails = ($attachOutput -join [Environment]::NewLine).Trim()
    throw "Artifact copy and remote cleanup succeeded, but ephemeral container '$ContainerName' did not terminate within $TerminationTimeoutSeconds seconds. kubectl attach exit code: $attachExitCode. $attachDetails"
}

$terminationReason = Get-PropertyValue -InputObject $terminatedState -Name 'reason'
$terminationExitCode = Get-PropertyValue -InputObject $terminatedState -Name 'exitCode'
Write-Host "Ephemeral container '$ContainerName' terminated (reason: $terminationReason; exit code: $terminationExitCode). Its immutable Pod record remains until the Pod is replaced."
