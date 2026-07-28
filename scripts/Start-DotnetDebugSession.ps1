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
    [string]$Image = 'ghcr.io/koepalex/dotnet-k8s-debug-containers/debug:latest',

    [ValidateNotNullOrEmpty()]
    [string]$ContainerName,

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

    [string[]]$AddCapability = @('SYS_PTRACE'),

    [Alias('SkipDiagnosticPortValidation')]
    [switch]$SkipSocketDiscoveryValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invokeParameters = @{
    Pod                          = $Pod
    TargetContainer              = $TargetContainer
    Namespace                    = $Namespace
    Image                        = $Image
    ContainerNamePrefix          = 'dotnet-debug'
    VolumeName                   = $VolumeName
    MountPath                    = $MountPath
    DiagnosticSocket             = $DiagnosticSocket
    Shell                        = $Shell
    StartupTimeoutSeconds        = $StartupTimeoutSeconds
    AddCapability                = $AddCapability
    SkipSocketDiscoveryValidation = $SkipSocketDiscoveryValidation
}

if ($PSBoundParameters.ContainsKey('ContainerName')) {
    $invokeParameters.ContainerName = $ContainerName
}

if ($PSBoundParameters.ContainsKey('WhatIf')) {
    $invokeParameters.WhatIf = $PSBoundParameters['WhatIf']
}

if ($PSBoundParameters.ContainsKey('Confirm')) {
    $invokeParameters.Confirm = $PSBoundParameters['Confirm']
}

$diagScript = Join-Path $PSScriptRoot 'Start-DotnetDiagSession.ps1'
& $diagScript @invokeParameters
