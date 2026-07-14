$workingDirectory = "$env:ProgramData\ImagemTI\Instalador"
$flagPath = Join-Path `
    $workingDirectory `
    'Flags\intune_staged.flag'
$runnerScript = Join-Path `
    $workingDirectory `
    'Intune\Executar-InstalacaoPersistente.ps1'

try {
    if (
        -not (Test-Path $flagPath) -or
        -not (Test-Path $runnerScript)
    ) {
        exit 1
    }

    $task = Get-ScheduledTask `
        -TaskPath '\ImagemTI\' `
        -TaskName 'Autopilot-InstalacaoEmpresa' `
        -ErrorAction Stop

    $action = @($task.Actions) |
        Select-Object -First 1

    if (
        $null -eq $action -or
        [string]$action.Arguments -notmatch
        'Executar-InstalacaoPersistente\.ps1'
    ) {
        exit 1
    }

    $version = ''

    try {
        $version = [string](
            Get-ItemPropertyValue `
                -Path 'HKLM:\SOFTWARE\ImagemTI\Instalador' `
                -Name 'IntuneBootstrapVersion' `
                -ErrorAction Stop
        )
    }
    catch {}

    if ([string]::IsNullOrWhiteSpace($version)) {
        Write-Output 'Preparo Intune detectado.'
    }
    else {
        Write-Output "Preparo Intune detectado. Versao: $version"
    }

    exit 0
}
catch {
    exit 1
}
