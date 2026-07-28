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
    [string]$DiagnosticSocket = '/diag/dotnet-diagnostic.sock',

    [ValidateNotNullOrEmpty()]
    [string]$Shell = '/bin/sh',

    [ValidateRange(1, 600)]
    [int]$StartupTimeoutSeconds = 60,

    [string[]]$AddCapability = @(),

    [Alias('SkipDiagnosticPortValidation')]
    [switch]$SkipSocketDiscoveryValidation
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
$DiagnosticSocket = ConvertTo-NormalizedContainerPath -Path $DiagnosticSocket -ParameterName 'DiagnosticSocket'
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

$targetVolumeMounts = @(Get-PropertyValue -InputObject $target -Name 'volumeMounts' | Where-Object {
        $_.name -eq $VolumeName -and $_.mountPath -eq $MountPath
    })
if ($targetVolumeMounts.Count -ne 1) {
    throw "Target container '$TargetContainer' must mount volume '$VolumeName' at '$MountPath'."
}

$targetVolumeMount = $targetVolumeMounts[0]
$targetSubPath = Get-PropertyValue -InputObject $targetVolumeMount -Name 'subPath'
$targetSubPathExpression = Get-PropertyValue -InputObject $targetVolumeMount -Name 'subPathExpr'
if ($targetSubPathExpression) {
    throw "Target container '$TargetContainer' uses subPathExpr for volume '$VolumeName'. Use a fixed subPath or mount the volume root so the ephemeral container can share the same directory."
}

if (-not $SkipSocketDiscoveryValidation) {
    $targetEnvironment = @(Get-PropertyValue -InputObject $target -Name 'env' | Where-Object {
            $null -ne $_
        })
    $tempDirectoryVariables = @($targetEnvironment | Where-Object {
            $_.name -eq 'TMPDIR'
        })
    $tempDirectoryValue = if ($tempDirectoryVariables.Count -eq 1) {
        Get-PropertyValue -InputObject $tempDirectoryVariables[0] -Name 'value'
    }
    else {
        $null
    }

    $usesSharedTempDirectory = $tempDirectoryValue -ceq $MountPath

    $diagnosticPortVariables = @($targetEnvironment | Where-Object {
            $_.name -eq 'DOTNET_DiagnosticPorts'
        })
    $diagnosticPortValue = if ($diagnosticPortVariables.Count -eq 1) {
        Get-PropertyValue -InputObject $diagnosticPortVariables[0] -Name 'value'
    }
    else {
        $null
    }

    $usesCustomDiagnosticPort = $false
    if ($diagnosticPortValue -and $DiagnosticSocket.StartsWith("$MountPath/", [StringComparison]::Ordinal)) {
        $diagnosticPortEntries = @($diagnosticPortValue -split ';')
        $usesCustomDiagnosticPort = @($diagnosticPortEntries | Where-Object {
                $_ -ceq "$DiagnosticSocket,connect,nosuspend"
            }).Count -gt 0
    }

    if (-not $usesSharedTempDirectory -and -not $usesCustomDiagnosticPort) {
        throw "Target container '$TargetContainer' must directly set TMPDIR='$MountPath' for automatic socket discovery, or DOTNET_DiagnosticPorts='$DiagnosticSocket,connect,nosuspend' for explicit-port mode. If configuration is supplied through envFrom or admission injection, rerun with -SkipSocketDiscoveryValidation."
    }
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
if ($targetSubPath) {
    $ephemeralVolumeMount.subPath = $targetSubPath
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
if ($AddCapability.Count -gt 0) {
    $ephemeralContainer.securityContext = [ordered]@{
        capabilities = [ordered]@{
            add = @($AddCapability)
        }
    }
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

$execCommand = "kubectl exec -it --namespace $Namespace pod/$Pod --container $ContainerName -- $Shell"
Write-Host "Ephemeral container '$ContainerName' is running."
Write-Host "Reconnect later with: $execCommand"
Write-Host "Attaching interactive session..."

& kubectl attach "pod/$Pod" --namespace $Namespace --container $ContainerName --stdin --tty
if ($LASTEXITCODE -ne 0) {
    throw "kubectl attach failed with exit code $LASTEXITCODE. Reconnect with: $execCommand"
}
