[CmdletBinding()]
param(
    [string]$WorkingDirectory = "$env:ProgramData\ImagemTI\Instalador"
)

$ErrorActionPreference = 'Stop'

Unregister-ScheduledTask `
    -TaskPath '\ImagemTI\' `
    -TaskName 'Autopilot-InstalacaoEmpresa' `
    -Confirm:$false `
    -ErrorAction SilentlyContinue

Remove-Item `
    -Path (Join-Path $WorkingDirectory 'Intune') `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue

Remove-Item `
    -Path (Join-Path $WorkingDirectory 'Inicializacao') `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue

$flagDirectory = Join-Path $WorkingDirectory 'Flags'

foreach ($flagName in @(
    'intune_staged.flag',
    'intune_retry_pending.flag',
    'intune_scheduled_completed.flag',
    'intune_scheduled_failed.flag',
    'installed_intunescheduled.flag',
    'failed_intunescheduled.flag'
)) {
    Remove-Item `
        -Path (Join-Path $flagDirectory $flagName) `
        -Force `
        -ErrorAction SilentlyContinue
}

$registryPath = 'HKLM:\SOFTWARE\ImagemTI\Instalador'

foreach ($valueName in @(
    'IntuneBootstrapVersion',
    'Repository',
    'Branch',
    'RepositoryRefType',
    'RepositoryRef',
    'FullInstallStatus',
    'FullInstallAttempt',
    'FullInstallLastMessage',
    'FullInstallLastRunAt',
    'FullInstallCompletedAt',
    'LastRepositoryVersion',
    'LastRunVersion',
    'LastRunTime',
    'LastMessage',
    'LastExitCode',
    'CompletedVersion',
    'CompletedTime',
    'Status'
)) {
    Remove-ItemProperty `
        -Path $registryPath `
        -Name $valueName `
        -Force `
        -ErrorAction SilentlyContinue
}

exit 0
