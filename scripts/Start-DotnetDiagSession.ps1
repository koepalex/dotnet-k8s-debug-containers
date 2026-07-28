[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Pod,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetContainer,

    [ValidateNotNullOrEmpty()]
    [string]$Namespace = 'default',

    [ValidateNotNullOrEmpty()]
    [string]$Image = 'ghcr.io/koepalex/dotnet-k8s-debug-containers/diag:latest',

    [ValidateNotNullOrEmpty()]
    [string]$ContainerName,

    [ValidateLength(1, 57)]
    [ValidatePattern('^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$')]
    [string]$ContainerNamePrefix = 'dotnet-diag',

    [ValidateNotNullOrEmpty()]
    [string]$VolumeName = 'diagnostics',

    [ValidateNotNullOrEmpty()]
    [string]$MountPath = '/diag',

    [ValidateNotNullOrEmpty()]
    [string]$Shell = '/bin/sh',

    [ValidateRange(1, 600)]
    [int]$StartupTimeoutSeconds = 60,

    [string[]]$AddCapability = @(),

    [switch]$RunAsRoot,

    [Alias('SkipDiagnosticPortValidation')]
    [switch]$SkipSocketDiscoveryValidation,

    [switch]$NoAttach
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Kubectl {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$StandardInput
    )

    if ($PSBoundParameters.ContainsKey('StandardInput')) {
        $output = $StandardInput | & kubectl @Arguments
    }
    else {
        $output = & kubectl @Arguments
    }

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

function Get-ContainerByName {
    param(
        [Parameter(Mandatory)]
        [object[]]$Containers,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return @($Containers | Where-Object { $_.name -eq $Name })
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

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl was not found on PATH.'
}

$MountPath = ConvertTo-NormalizedContainerPath -Path $MountPath -ParameterName 'MountPath'
if ($MountPath -eq '/') {
    throw 'MountPath cannot be the container root because the emptyDir mount would hide the diagnostics image filesystem.'
}

$podObject = Get-Pod

if (Get-PropertyValue -InputObject $podObject.metadata -Name 'deletionTimestamp') {
    throw "Pod '$Namespace/$Pod' is terminating."
}

$targetContainers = @(Get-ContainerByName -Containers @($podObject.spec.containers) -Name $TargetContainer)
if ($targetContainers.Count -ne 1) {
    $availableContainers = @($podObject.spec.containers | ForEach-Object { $_.name }) -join ', '
    throw "Target container '$TargetContainer' was not found in Pod '$Namespace/$Pod'. Available containers: $availableContainers"
}

$target = $targetContainers[0]
$volumes = @(Get-PropertyValue -InputObject $podObject.spec -Name 'volumes' | Where-Object {
        $_.name -eq $VolumeName
    })
if ($volumes.Count -ne 1) {
    throw "Pod '$Namespace/$Pod' does not declare volume '$VolumeName'. Add a shared emptyDir volume to the workload template first."
}

$diagnosticsVolume = $volumes[0]
if ($diagnosticsVolume.PSObject.Properties.Name -notcontains 'emptyDir') {
    throw "Pod volume '$VolumeName' must be an emptyDir volume so the diagnostics container can create the Unix socket and collected artifacts."
}

$existingEphemeralContainers = @(Get-PropertyValue -InputObject $podObject.spec -Name 'ephemeralContainers' | Where-Object {
        $null -ne $_
    })

if (-not $ContainerName) {
    do {
        $ContainerName = "$ContainerNamePrefix-$([Guid]::NewGuid().ToString('N').Substring(0, 5))"
    } while (@($existingEphemeralContainers | Where-Object { $_.name -eq $ContainerName }).Count -gt 0)
}

if ($ContainerName.Length -gt 63 -or $ContainerName -notmatch '^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$') {
    throw "Ephemeral container name '$ContainerName' must be a valid DNS label with at most 63 characters."
}

if (@($existingEphemeralContainers | Where-Object { $_.name -eq $ContainerName }).Count -gt 0) {
    throw "Ephemeral container '$ContainerName' already exists in Pod '$Namespace/$Pod'. Ephemeral containers cannot be restarted or replaced."
}

$ephemeralVolumeMount = [ordered]@{
    name      = $VolumeName
    mountPath = $MountPath
}

$ephemeralContainer = [ordered]@{
    name                = $ContainerName
    image               = $Image
    command             = @($Shell)
    stdin               = $true
    tty                 = $true
    targetContainerName = $TargetContainer
    env                 = @(
        [ordered]@{
            name  = 'TMPDIR'
            value = $MountPath
        }
    )
    volumeMounts        = @($ephemeralVolumeMount)
}
if ($AddCapability.Count -gt 0 -or $RunAsRoot) {
    $securityContext = [ordered]@{}

    if ($RunAsRoot) {
        $securityContext.runAsUser = 0
        $securityContext.runAsNonRoot = $false
        $securityContext.allowPrivilegeEscalation = $true
        $securityContext.seccompProfile = [ordered]@{
            type = 'Unconfined'
        }
    }

    if ($AddCapability.Count -gt 0) {
        $securityContext.capabilities = [ordered]@{
            add = @($AddCapability)
        }
    }

    $ephemeralContainer.securityContext = $securityContext
}

$updatedEphemeralContainers = @($existingEphemeralContainers) + @($ephemeralContainer)
if ($podObject.spec.PSObject.Properties.Name -contains 'ephemeralContainers') {
    $podObject.spec.ephemeralContainers = $updatedEphemeralContainers
}
else {
    $podObject.spec | Add-Member -NotePropertyName ephemeralContainers -NotePropertyValue $updatedEphemeralContainers
}

$payload = $podObject | ConvertTo-Json -Depth 100 -Compress
$resourcePath = "/api/v1/namespaces/$([Uri]::EscapeDataString($Namespace))/pods/$([Uri]::EscapeDataString($Pod))/ephemeralcontainers"

if (-not $PSCmdlet.ShouldProcess(
        "$Namespace/$Pod",
        "Add ephemeral container '$ContainerName' with volume '$VolumeName' mounted at '$MountPath'"
    )) {
    Write-Output $payload
    return
}

Write-Host "Creating ephemeral container '$ContainerName' in Pod '$Namespace/$Pod'..."
Invoke-Kubectl -Arguments @('replace', '--raw', $resourcePath, '--filename', '-') -StandardInput $payload | Out-Null

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$lastWaitingReason = $null
$containerStatus = $null

while ($stopwatch.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
    $podObject = Get-Pod
    $ephemeralContainerStatuses = @(Get-PropertyValue -InputObject $podObject.status -Name 'ephemeralContainerStatuses' | Where-Object {
            $null -ne $_
        })
    $containerStatus = @($ephemeralContainerStatuses | Where-Object {
            $_.name -eq $ContainerName
        }) | Select-Object -First 1
    $containerState = Get-PropertyValue -InputObject $containerStatus -Name 'state'
    $runningState = Get-PropertyValue -InputObject $containerState -Name 'running'
    $terminatedState = Get-PropertyValue -InputObject $containerState -Name 'terminated'
    $waitingState = Get-PropertyValue -InputObject $containerState -Name 'waiting'

    if ($runningState) {
        break
    }

    if ($terminatedState) {
        $terminatedReason = Get-PropertyValue -InputObject $terminatedState -Name 'reason'
        $terminatedExitCode = Get-PropertyValue -InputObject $terminatedState -Name 'exitCode'
        $terminatedMessage = Get-PropertyValue -InputObject $terminatedState -Name 'message'
        throw "Ephemeral container '$ContainerName' terminated before attachment (reason: $terminatedReason; exit code: $terminatedExitCode; message: $terminatedMessage)."
    }

    $waitingReason = Get-PropertyValue -InputObject $waitingState -Name 'reason'
    if ($waitingReason -and $waitingReason -ne $lastWaitingReason) {
        $lastWaitingReason = $waitingReason
        Write-Host "Waiting for '$ContainerName': $lastWaitingReason"
    }

    Start-Sleep -Seconds 1
}

if (-not $containerStatus -or -not (Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $containerStatus -Name 'state') -Name 'running')) {
    throw "Timed out after $StartupTimeoutSeconds seconds waiting for ephemeral container '$ContainerName' to start."
}

$socketBridgeScript = @'
set -eu
shared_dir=$1
found=0

for process_dir in /proc/[0-9]*; do
  [ -r "$process_dir/environ" ] || continue

  target_tmp=/tmp
  tmp_entry=$({ tr '\000' '\n' < "$process_dir/environ"; } 2>/dev/null | grep -m 1 '^TMPDIR=' || true)
  if [ -n "$tmp_entry" ]; then
    target_tmp=${tmp_entry#TMPDIR=}
  fi

  case "$target_tmp" in
    /*) ;;
    *) target_tmp=/tmp ;;
  esac

  for socket in "$process_dir/root$target_tmp"/dotnet-diagnostic-*-socket; do
    [ -S "$socket" ] || continue

    name=${socket##*/}
    destination="$shared_dir/$name"

    if [ -L "$destination" ] && [ ! -e "$destination" ]; then
      rm -f "$destination"
    fi

    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
      ln -s "$socket" "$destination"
    fi

    if [ -S "$destination" ]; then
      found=1
    fi
  done
done

if [ "$found" -eq 0 ]; then
  echo "No accessible .NET default diagnostic sockets were found." >&2
  exit 42
fi

echo "$found"
'@
$socketBridgeScript = $socketBridgeScript.Replace("`r`n", "`n")

Write-Host 'Preparing .NET diagnostic socket discovery...'
try {
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
        $socketBridgeScript,
        '--',
        $MountPath
    ) | Out-Null
    Write-Host 'Prepared .NET diagnostic socket discovery.'
}
catch {
    if (-not $SkipSocketDiscoveryValidation) {
        throw "Ephemeral container '$ContainerName' is running, but .NET socket discovery could not be prepared. Ensure the target process has diagnostics enabled and runs as the same UID. $($_.Exception.Message)"
    }

    Write-Warning "Socket discovery could not be prepared: $($_.Exception.Message)"
}

$execCommand = "kubectl exec -it --namespace $Namespace pod/$Pod --container $ContainerName -- $Shell"
$processCommand = "kubectl exec --namespace $Namespace pod/$Pod --container $ContainerName -- /tools/dotnet-trace ps"
Write-Host "Ephemeral container '$ContainerName' is running."
Write-Host "Reconnect later with: $execCommand"
Write-Host "List .NET processes with: $processCommand"

if ($NoAttach) {
    return
}

Write-Host "Attaching interactive session..."

& kubectl attach "pod/$Pod" --namespace $Namespace --container $ContainerName --stdin --tty
if ($LASTEXITCODE -ne 0) {
    throw "kubectl attach failed with exit code $LASTEXITCODE. Reconnect with: $execCommand"
}
