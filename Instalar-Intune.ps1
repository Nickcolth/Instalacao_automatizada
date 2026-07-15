[CmdletBinding()]
param(
    [string]$Repository = 'Nickcolth/Instalacao_automatizada',
    [string]$Branch = 'main',
    [string]$WorkingDirectory = "$env:ProgramData\ImagemTI\Instalador",
    [string]$PackageVersion = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
    $versionPath = Join-Path $PSScriptRoot 'VERSION.txt'

    if (Test-Path $versionPath) {
        $PackageVersion = (
            Get-Content `
                -Path $versionPath `
                -Raw `
                -Encoding UTF8
        ).Trim()
    }
}

if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
    $PackageVersion = 'sem-versao'
}

$taskPath = '\ImagemTI\'
$taskName = 'Autopilot-InstalacaoEmpresa'
$logDirectory = Join-Path $WorkingDirectory 'Logs'
$flagDirectory = Join-Path $WorkingDirectory 'Flags'
$secureDirectory = Join-Path $WorkingDirectory 'Segredos'
$scriptDirectory = Join-Path $WorkingDirectory 'Intune'
$bootstrapDirectory = Join-Path $WorkingDirectory 'Inicializacao'
$registryPath = 'HKLM:\SOFTWARE\ImagemTI\Instalador'

New-Item `
    -Path @(
        $WorkingDirectory,
        $logDirectory,
        $flagDirectory,
        $secureDirectory,
        $scriptDirectory,
        $bootstrapDirectory,
        $registryPath
    ) `
    -ItemType Directory `
    -Force |
    Out-Null

$logPath = Join-Path $logDirectory 'intune-bootstrap.log'

function Write-StageLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
        $Level, `
        $Message

    $line | Out-File `
        -FilePath $logPath `
        -Append `
        -Encoding utf8

    Write-Host $line
}

Write-StageLog "Iniciando preparo Intune. Versao: $PackageVersion."

foreach ($flagName in @(
    'intune_staged.flag',
    'intune_retry_pending.flag',
    'intune_scheduled_completed.flag',
    'intune_scheduled_failed.flag',
    'intune_critical_completed.flag',
    'installed_intunecritical.flag',
    'failed_intunecritical.flag',
    'installed_intunescheduled.flag',
    'failed_intunescheduled.flag'
)) {
    Remove-Item `
        -Path (Join-Path $flagDirectory $flagName) `
        -Force `
        -ErrorAction SilentlyContinue
}

foreach ($valueName in @(
    'FullInstallStatus',
    'FullInstallAttempt',
    'FullInstallLastMessage',
    'FullInstallLastRunAt',
    'FullInstallCompletedAt',
    'CompletedVersion',
    'CompletedTime',
    'LastRepositoryVersion',
    'LastExitCode'
)) {
    Remove-ItemProperty `
        -Path $registryPath `
        -Name $valueName `
        -Force `
        -ErrorAction SilentlyContinue
}

$packageSecureDirectory = Join-Path $PSScriptRoot 'Segredos'

if (Test-Path $packageSecureDirectory) {
    Copy-Item `
        -Path (Join-Path $packageSecureDirectory '*') `
        -Destination $secureDirectory `
        -Recurse `
        -Force `
        -ErrorAction Stop

    Write-StageLog (
        "Arquivos de configuracao copiados para $secureDirectory."
    )
}

$runnerSource = Join-Path `
    $PSScriptRoot `
    'Executar-InstalacaoPersistente.ps1'

if (-not (Test-Path $runnerSource)) {
    throw 'Executor persistente nao foi encontrado no pacote.'
}

$runnerDestination = Join-Path `
    $scriptDirectory `
    'Executar-InstalacaoPersistente.ps1'

Copy-Item `
    -Path $runnerSource `
    -Destination $runnerDestination `
    -Force `
    -ErrorAction Stop

Remove-Item `
    -Path (Join-Path $bootstrapDirectory '00-IniciarInstalacaoGitHub.ps1') `
    -Force `
    -ErrorAction SilentlyContinue

$arguments = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f $runnerDestination),
    '-Repository', ('"{0}"' -f $Repository),
    '-Branch', ('"{0}"' -f $Branch),
    '-PackageVersion', ('"{0}"' -f $PackageVersion),
    '-WorkingDirectory', ('"{0}"' -f $WorkingDirectory),
    '-DesktopWaitMinutes', '20',
    '-DesktopRetrySeconds', '15',
    '-InternetWaitMinutes', '30',
    '-InternetRetrySeconds', '30'
) -join ' '

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $arguments

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn

$repeatTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(3) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 8)

Register-ScheduledTask `
    -TaskPath $taskPath `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($logonTrigger, $repeatTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Description (
        'Instala os agentes criticos desde o provisionamento, aguarda ' +
        'o desktop para as demais tarefas e tenta novamente a cada ' +
        '15 minutos ate concluir.'
    ) `
    -Force |
    Out-Null

$registeredTask = Get-ScheduledTask `
    -TaskPath $taskPath `
    -TaskName $taskName `
    -ErrorAction Stop

$registeredAction = @($registeredTask.Actions) |
    Select-Object -First 1

if (
    $null -eq $registeredAction -or
    [string]$registeredAction.Arguments -notmatch
    'Executar-InstalacaoPersistente\.ps1'
) {
    throw 'A tarefa foi criada com uma acao inesperada.'
}

Set-Content `
    -Path (Join-Path $flagDirectory 'intune_staged.flag') `
    -Value (
        "Version=$PackageVersion`r`n" +
        "Repository=$Repository`r`n" +
        "Branch=$Branch`r`n" +
        "Date=$((Get-Date).ToString('o'))"
    ) `
    -Encoding ASCII `
    -Force

foreach ($property in @(
    @('IntuneBootstrapVersion', $PackageVersion),
    @('Repository', $Repository),
    @('Branch', $Branch),
    @('FullInstallStatus', 'StartingCriticalPhase')
)) {
    New-ItemProperty `
        -Path $registryPath `
        -Name $property[0] `
        -Value $property[1] `
        -PropertyType String `
        -Force |
        Out-Null
}

try {
    Start-ScheduledTask `
        -TaskPath $taskPath `
        -TaskName $taskName `
        -ErrorAction Stop

    Write-StageLog `
        -Message (
            'Tarefa iniciada imediatamente para executar a fase ' +
            'critica durante o provisionamento.'
        ) `
        -Level 'SUCCESS'
}
catch {
    Write-StageLog `
        -Message (
            'Nao foi possivel iniciar a tarefa imediatamente: ' +
            "$($_.Exception.Message). O gatilho automatico permanece " +
            'ativo.'
        ) `
        -Level 'WARN'
}

Write-StageLog `
    -Message (
        "Preparo concluido. Tarefa criada: $taskPath$taskName. " +
        'A fase critica inicia imediatamente; o gatilho de seguranca ' +
        'executa em ate 3 minutos e depois a cada 15 minutos.'
    ) `
    -Level 'SUCCESS'

exit 0
