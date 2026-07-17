[CmdletBinding()]
param(
    [string]$Repository = 'Nickcolth/Instalacao_automatizada',
    [string]$Branch = 'main',
    [string]$PackageVersion = 'sem-versao',
    [string]$WorkingDirectory = "$env:ProgramData\ImagemTI\Instalador",
    [int]$DesktopWaitMinutes = 20,
    [int]$DesktopRetrySeconds = 15,
    [int]$InternetWaitMinutes = 30,
    [int]$InternetRetrySeconds = 30
)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12
}
catch {}

$taskPath = '\ImagemTI\'
$taskName = 'Autopilot-InstalacaoEmpresa'
$flagDirectory = Join-Path $WorkingDirectory 'Flags'
$logDirectory = Join-Path $WorkingDirectory 'Logs'
$bootstrapDirectory = Join-Path $WorkingDirectory 'Inicializacao'
$secureDirectory = Join-Path $WorkingDirectory 'Segredos'
$registryPath = 'HKLM:\SOFTWARE\ImagemTI\Instalador'

New-Item `
    -Path @(
        $flagDirectory,
        $logDirectory,
        $bootstrapDirectory,
        $secureDirectory,
        $registryPath
    ) `
    -ItemType Directory `
    -Force |
    Out-Null

$logPath = Join-Path `
    $logDirectory `
    'intune-execucao-agendada.log'

function Write-RunnerLog {
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

function Get-UserNameOnly {
    param([string]$IdentityName)

    if ([string]::IsNullOrWhiteSpace($IdentityName)) {
        return ''
    }

    if ($IdentityName -like '*\*') {
        return (($IdentityName -split '\\')[-1])
    }

    return $IdentityName
}

function Test-ProvisioningInterfaceActive {
    foreach ($processName in @(
        'CloudExperienceHost',
        'msoobe',
        'UserOOBEBroker'
    )) {
        if (
            Get-Process `
                -Name $processName `
                -ErrorAction SilentlyContinue
        ) {
            return $true
        }
    }

    return $false
}

function Get-ReadyDesktopUsers {
    param([int]$MinimumExplorerAgeSeconds = 60)

    $users = @()

    try {
        $explorerProcesses = @(
            Get-CimInstance `
                -ClassName Win32_Process `
                -Filter "Name = 'explorer.exe'" `
                -ErrorAction Stop
        )

        foreach ($explorerProcess in $explorerProcesses) {
            try {
                $owner = Invoke-CimMethod `
                    -InputObject $explorerProcess `
                    -MethodName GetOwner `
                    -ErrorAction Stop

                if (
                    $null -eq $owner -or
                    [int]$owner.ReturnValue -ne 0
                ) {
                    continue
                }

                $userName = Get-UserNameOnly `
                    -IdentityName ([string]$owner.User)

                if (
                    [string]::IsNullOrWhiteSpace($userName) -or
                    $userName -ieq 'Imagem' -or
                    $userName -ieq 'defaultuser0' -or
                    $userName -like 'DWM-*' -or
                    $userName -like 'UMFD-*'
                ) {
                    continue
                }

                $process = Get-Process `
                    -Id ([int]$explorerProcess.ProcessId) `
                    -ErrorAction Stop

                $ageSeconds = (
                    (Get-Date) - $process.StartTime
                ).TotalSeconds

                if ($ageSeconds -lt $MinimumExplorerAgeSeconds) {
                    continue
                }

                $users += [pscustomobject]@{
                    UserName = $userName
                    SessionId = [int]$explorerProcess.SessionId
                    ExplorerAgeSeconds = [int]$ageSeconds
                }
            }
            catch {
                continue
            }
        }
    }
    catch {}

    return @(
        $users |
            Sort-Object UserName, SessionId -Unique
    )
}

function Wait-ForReadyDesktop {
    param(
        [int]$WaitMinutes,
        [int]$RetrySeconds
    )

    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $attempt = 0

    do {
        $attempt++

        $users = @(
            Get-ReadyDesktopUsers `
                -MinimumExplorerAgeSeconds 60
        )

        if ($users.Count -gt 0) {
            $provisioningStillActive = (
                Test-ProvisioningInterfaceActive
            )

            if ($provisioningStillActive) {
                Write-RunnerLog `
                    -Message (
                        'Desktop real encontrado mesmo com processo ' +
                        'residual do OOBE ativo. O Explorer do ' +
                        'colaborador tera prioridade.'
                    ) `
                    -Level 'WARN'
            }

            Write-RunnerLog `
                -Message (
                    'Desktop real confirmado para: ' +
                    (($users.UserName) -join ', ') +
                    '.'
                ) `
                -Level 'SUCCESS'

            return $users
        }

        if (Test-ProvisioningInterfaceActive) {
            Write-RunnerLog (
                "OOBE ainda ativo e nenhum Explorer valido foi " +
                "encontrado. Verificacao $attempt."
            )
        }
        else {
            Write-RunnerLog (
                "Desktop ainda nao esta pronto. Verificacao $attempt."
            )
        }

        Start-Sleep -Seconds $RetrySeconds
    }
    while ((Get-Date) -lt $deadline)

    return @()
}

function Test-PowerShellFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    $item = Get-Item -Path $Path -ErrorAction Stop

    if ($item.Length -lt 4096) {
        return $false
    }

    $tokens = $null
    $parseErrors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    return @($parseErrors).Count -eq 0
}

function Download-BootstrapWithInternetWait {
    param(
        [string]$Uri,
        [string]$Destination,
        [int]$WaitMinutes,
        [int]$RetrySeconds
    )

    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $attempt = 0

    do {
        $attempt++

        try {
            Remove-Item `
                -Path $Destination `
                -Force `
                -ErrorAction SilentlyContinue

            Invoke-WebRequest `
                -Uri $Uri `
                -OutFile $Destination `
                -UseBasicParsing `
                -TimeoutSec 120 `
                -Headers @{
                    'User-Agent' = 'ImagemTI-IntuneRunner'
                    'Cache-Control' = 'no-cache'
                    'Pragma' = 'no-cache'
                } `
                -ErrorAction Stop

            if (-not (Test-PowerShellFile -Path $Destination)) {
                throw 'O bootstrap recebido nao e um script valido.'
            }

            Write-RunnerLog `
                -Message (
                    'Internet e bootstrap atual do GitHub confirmados ' +
                    "na tentativa $attempt."
                ) `
                -Level 'SUCCESS'

            return $true
        }
        catch {
            Write-RunnerLog `
                -Message (
                    "Sem acesso valido ao GitHub na tentativa " +
                    "${attempt}: $($_.Exception.Message)"
                ) `
                -Level 'WARN'

            if ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds $RetrySeconds
            }
        }
    }
    while ((Get-Date) -lt $deadline)

    return $false
}

function Get-ExecutionAttempt {
    try {
        return [int](
            Get-ItemPropertyValue `
                -Path $registryPath `
                -Name 'FullInstallAttempt' `
                -ErrorAction Stop
        )
    }
    catch {
        return 0
    }
}

function Set-ExecutionStatus {
    param(
        [string]$Status,
        [int]$Attempt,
        [string]$Message
    )

    foreach ($property in @(
        @('FullInstallStatus', $Status, 'String'),
        @('FullInstallAttempt', $Attempt, 'DWord'),
        @('FullInstallLastMessage', $Message, 'String'),
        @(
            'FullInstallLastRunAt',
            (Get-Date).ToString('o'),
            'String'
        )
    )) {
        New-ItemProperty `
            -Path $registryPath `
            -Name $property[0] `
            -Value $property[1] `
            -PropertyType $property[2] `
            -Force |
            Out-Null
    }
}

function Invoke-BootstrapPhase {
    param(
        [string]$BootstrapPath,
        [string]$ExecutionMode,
        [string]$PhaseName
    )

    Write-RunnerLog (
        "Iniciando $PhaseName. Modo do instalador: $ExecutionMode."
    )

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $BootstrapPath),
        '-Mode', $ExecutionMode,
        '-Repository', ('"{0}"' -f $Repository),
        '-Branch', ('"{0}"' -f $Branch),
        '-PackageVersion', ('"{0}"' -f $PackageVersion),
        '-WorkingDirectory', ('"{0}"' -f $WorkingDirectory),
        '-SecureRoot', ('"{0}"' -f $secureDirectory),
        '-KeepFiles'
    ) -join ' '

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    Write-RunnerLog `
        -Message (
            "$PhaseName finalizada com ExitCode " +
            "$($process.ExitCode)."
        ) `
        -Level $(
            if ($process.ExitCode -eq 0) {
                'SUCCESS'
            }
            else {
                'ERROR'
            }
        )

    return [int]$process.ExitCode
}

$completedFlag = Join-Path `
    $flagDirectory `
    'intune_scheduled_completed.flag'

$criticalCompletedFlag = Join-Path `
    $flagDirectory `
    'intune_critical_completed.flag'

$retryPendingFlag = Join-Path `
    $flagDirectory `
    'intune_retry_pending.flag'

if (Test-Path $completedFlag) {
    Set-ExecutionStatus `
        -Status 'Completed' `
        -Attempt (Get-ExecutionAttempt) `
        -Message 'Instalacao completa encontrada.'

    Write-RunnerLog `
        -Message (
            'Instalacao completa ja confirmada. A tarefa sera ' +
            'desativada.'
        ) `
        -Level 'SUCCESS'

    Disable-ScheduledTask `
        -TaskPath $taskPath `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue |
        Out-Null

    exit 0
}

$bootstrapPath = Join-Path `
    $bootstrapDirectory `
    '00-IniciarInstalacaoGitHub.ps1'

$bootstrapUrl = [string]::Format(
    [Globalization.CultureInfo]::InvariantCulture,
    (
        'https://raw.githubusercontent.com/{0}/{1}/' +
        '00-Inicializacao/00-IniciarInstalacaoGitHub.ps1'
    ),
    $Repository,
    [Uri]::EscapeDataString($Branch)
)

$criticalAttempt = 0

while (-not (Test-Path $criticalCompletedFlag)) {
    $criticalAttempt++

    $internetReady = Download-BootstrapWithInternetWait `
        -Uri $bootstrapUrl `
        -Destination $bootstrapPath `
        -WaitMinutes $InternetWaitMinutes `
        -RetrySeconds $InternetRetrySeconds

    if (-not $internetReady) {
        Set-Content `
            -Path $retryPendingFlag `
            -Value (
                '{0}|Phase=Critical|Step=Internet|Attempt={1}' -f `
                    (Get-Date).ToString('o'), `
                    $criticalAttempt
            ) `
            -Encoding ASCII `
            -Force

        Set-ExecutionStatus `
            -Status 'WaitingForInternet' `
            -Attempt $criticalAttempt `
            -Message (
                'Sem acesso ao bootstrap do GitHub durante a fase ' +
                'critica. Nova tentativa em 60 segundos.'
            )

        Write-RunnerLog `
            -Message (
                'Fase critica sem acesso ao GitHub. Nova tentativa em ' +
                '60 segundos.'
            ) `
            -Level 'WARN'

        Start-Sleep -Seconds 60
        continue
    }

    Set-ExecutionStatus `
        -Status 'InstallingCriticalAgents' `
        -Attempt $criticalAttempt `
        -Message (
            'Instalando Atlas, Journey, Sophos e Guardian antes de ' +
            'aguardar o desktop.'
        )

    Write-RunnerLog `
        -Message (
            'FASE CRITICA: iniciando Atlas -> Journey -> Sophos -> ' +
            "Guardian. Tentativa $criticalAttempt. Esta fase pode " +
            'executar durante o OOBE.'
        ) `
        -Level 'WARN'

    $criticalExitCode = Invoke-BootstrapPhase `
        -BootstrapPath $bootstrapPath `
        -ExecutionMode 'IntuneCritical' `
        -PhaseName 'fase critica'

    if ($criticalExitCode -eq 0) {
        Set-Content `
            -Path $criticalCompletedFlag `
            -Value (
                "Version=$PackageVersion`r`n" +
                "Date=$((Get-Date).ToString('o'))`r`n" +
                "Attempt=$criticalAttempt"
            ) `
            -Encoding ASCII `
            -Force

        Remove-Item `
            -Path $retryPendingFlag `
            -Force `
            -ErrorAction SilentlyContinue

        Remove-Item `
            -Path (
                Join-Path $flagDirectory 'failed_intunecritical.flag'
            ) `
            -Force `
            -ErrorAction SilentlyContinue

        Write-RunnerLog `
            -Message (
                'FASE CRITICA CONCLUIDA: Atlas, Journey, Sophos e ' +
                'Guardian foram confirmados.'
            ) `
            -Level 'SUCCESS'

        break
    }

    Set-Content `
        -Path $retryPendingFlag `
        -Value (
            '{0}|Phase=Critical|ExitCode={1}|Attempt={2}' -f `
                (Get-Date).ToString('o'), `
                $criticalExitCode, `
                $criticalAttempt
        ) `
        -Encoding ASCII `
        -Force

    Set-ExecutionStatus `
        -Status 'CriticalPendingRetry' `
        -Attempt $criticalAttempt `
        -Message (
            "Fase critica nao concluida. ExitCode: " +
            "$criticalExitCode. Nova tentativa em 60 segundos."
        )

    Write-RunnerLog `
        -Message (
            'A fase critica nao foi concluida. Nenhuma instalacao ' +
            'dependente do usuario sera iniciada. Nova tentativa em ' +
            '60 segundos.'
        ) `
        -Level 'ERROR'

    Start-Sleep -Seconds 60
}

$attempt = $criticalAttempt
Set-ExecutionStatus `
    -Status 'CriticalReadyWaitingForDesktop' `
    -Attempt $attempt `
    -Message (
        'Agentes criticos confirmados. Aguardando o desktop real para ' +
        'continuar.'
    )

$desktopUsers = @(
    Wait-ForReadyDesktop `
        -WaitMinutes $DesktopWaitMinutes `
        -RetrySeconds $DesktopRetrySeconds
)

if ($desktopUsers.Count -eq 0) {
    Remove-Item `
        -Path $retryPendingFlag `
        -Force `
        -ErrorAction SilentlyContinue

    Write-RunnerLog `
        -Message (
            'Os agentes criticos estao instalados, mas o desktop real ' +
            'ainda nao esta pronto. O restante sera executado em uma ' +
            'proxima rodada.'
        ) `
        -Level 'SUCCESS'

    exit 10
}

Set-ExecutionStatus `
    -Status 'Running' `
    -Attempt $attempt `
    -Message 'Executando a preparacao completa depois do desktop.'

Write-RunnerLog (
    "Iniciando tentativa completa numero $attempt."
)

$fullExitCode = Invoke-BootstrapPhase `
    -BootstrapPath $bootstrapPath `
    -ExecutionMode 'IntuneScheduled' `
    -PhaseName 'preparacao completa'

if (
    $fullExitCode -eq 0 -and
    (Test-Path $completedFlag)
) {
    Remove-Item `
        -Path $retryPendingFlag `
        -Force `
        -ErrorAction SilentlyContinue

    Set-ExecutionStatus `
        -Status 'Completed' `
        -Attempt $attempt `
        -Message 'Instalacao completa confirmada.'

    New-ItemProperty `
        -Path $registryPath `
        -Name 'FullInstallCompletedAt' `
        -Value (Get-Date).ToString('o') `
        -PropertyType String `
        -Force |
        Out-Null

    Write-RunnerLog `
        -Message (
            "Instalacao completa confirmada na tentativa $attempt. " +
            'A tarefa sera desativada.'
        ) `
        -Level 'SUCCESS'

    Disable-ScheduledTask `
        -TaskPath $taskPath `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue |
        Out-Null

    exit 0
}

Set-Content `
    -Path $retryPendingFlag `
    -Value (
        '{0}|Phase=Full|ExitCode={1}|Attempt={2}' -f `
            (Get-Date).ToString('o'), `
            $fullExitCode, `
            $attempt
    ) `
    -Encoding ASCII `
    -Force

Set-ExecutionStatus `
    -Status 'PendingRetry' `
    -Attempt $attempt `
    -Message (
        "Instalacao completa nao concluida. ExitCode: $fullExitCode."
    )

Write-RunnerLog `
    -Message (
        "Tentativa completa $attempt nao concluiu a instalacao. " +
        "ExitCode: $fullExitCode. A tarefa tentara novamente."
    ) `
    -Level 'ERROR'

exit 30
