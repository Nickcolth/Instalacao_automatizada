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

        if (-not (Test-ProvisioningInterfaceActive)) {
            $users = @(
                Get-ReadyDesktopUsers `
                    -MinimumExplorerAgeSeconds 60
            )

            if ($users.Count -gt 0) {
                Write-RunnerLog `
                    -Message (
                        'Desktop real confirmado para: ' +
                        (($users.UserName) -join ', ') +
                        '.'
                    ) `
                    -Level 'SUCCESS'

                return $users
            }
        }

        Write-RunnerLog (
            "Desktop ainda nao esta pronto. Verificacao $attempt."
        )

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
        @('FullInstallLastRunAt', (Get-Date).ToString('o'), 'String')
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

$completedFlag = Join-Path `
    $flagDirectory `
    'intune_scheduled_completed.flag'

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

$desktopUsers = @(
    Wait-ForReadyDesktop `
        -WaitMinutes $DesktopWaitMinutes `
        -RetrySeconds $DesktopRetrySeconds
)

if ($desktopUsers.Count -eq 0) {
    Set-ExecutionStatus `
        -Status 'WaitingForDesktop' `
        -Attempt (Get-ExecutionAttempt) `
        -Message 'Desktop real ainda nao disponivel.'

    exit 10
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

$internetReady = Download-BootstrapWithInternetWait `
    -Uri $bootstrapUrl `
    -Destination $bootstrapPath `
    -WaitMinutes $InternetWaitMinutes `
    -RetrySeconds $InternetRetrySeconds

if (-not $internetReady) {
    Set-Content `
        -Path (Join-Path $flagDirectory 'intune_retry_pending.flag') `
        -Value (Get-Date).ToString('o') `
        -Encoding ASCII `
        -Force

    Set-ExecutionStatus `
        -Status 'WaitingForInternet' `
        -Attempt (Get-ExecutionAttempt) `
        -Message 'Sem acesso ao bootstrap do GitHub.'

    exit 20
}

$attempt = (Get-ExecutionAttempt) + 1

Set-ExecutionStatus `
    -Status 'Running' `
    -Attempt $attempt `
    -Message 'Executando instalacao corporativa.'

Write-RunnerLog (
    "Iniciando tentativa persistente numero $attempt."
)

$arguments = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f $bootstrapPath),
    '-Mode', 'IntuneScheduled',
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

if (
    $process.ExitCode -eq 0 -and
    (Test-Path $completedFlag)
) {
    Remove-Item `
        -Path (Join-Path $flagDirectory 'intune_retry_pending.flag') `
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
    -Path (Join-Path $flagDirectory 'intune_retry_pending.flag') `
    -Value (
        '{0}|ExitCode={1}|Attempt={2}' -f `
            (Get-Date).ToString('o'), `
            $process.ExitCode, `
            $attempt
    ) `
    -Encoding ASCII `
    -Force

Set-ExecutionStatus `
    -Status 'PendingRetry' `
    -Attempt $attempt `
    -Message (
        "Instalacao nao concluida. ExitCode: $($process.ExitCode)."
    )

Write-RunnerLog `
    -Message (
        "Tentativa $attempt nao concluiu a instalacao. ExitCode: " +
        "$($process.ExitCode). A tarefa tentara novamente."
    ) `
    -Level 'ERROR'

exit 30
