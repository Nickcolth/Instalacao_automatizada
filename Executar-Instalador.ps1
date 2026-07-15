[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Manual','IntuneCritical','IntuneScheduled')]
    [string]$Mode,

    [string]$RepositoryRoot = $PSScriptRoot,

    [int]$MaxInstallAttempts = 3,

    [string]$PackageVersion = 'sem-versao'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Import-Module (Join-Path $RepositoryRoot '10-Nucleo\Instalador.Nucleo.psm1') -Force

function Get-ProfileIntValue {
    param($Profile, [string[]]$Names, [int]$Default)
    foreach ($name in $Names) {
        if ($Profile.PSObject.Properties.Name -contains $name -and $null -ne $Profile.PSObject.Properties[$name].Value) {
            try { return [int]$Profile.PSObject.Properties[$name].Value } catch { return $Default }
        }
    }
    return $Default
}

function Get-ProfileTaskList {
    param($Profile)
    if ($Profile.PSObject.Properties.Name -contains 'tarefas') {
        return @($Profile.tarefas | ForEach-Object { [string]$_ })
    }
    if ($Profile.PSObject.Properties.Name -contains 'tasks') {
        return @($Profile.tasks | ForEach-Object { [string]$_ })
    }
    return @()
}


function Get-OfficeSuiteMissingComponents {
    $components = @(
        [pscustomobject]@{
            Name = 'Microsoft 365'
            Paths = @(
                'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE',
                'C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE'
            )
        },
        [pscustomobject]@{
            Name = 'Microsoft Project'
            Paths = @(
                'C:\Program Files\Microsoft Office\root\Office16\WINPROJ.EXE',
                'C:\Program Files (x86)\Microsoft Office\root\Office16\WINPROJ.EXE'
            )
        },
        [pscustomobject]@{
            Name = 'Microsoft Visio'
            Paths = @(
                'C:\Program Files\Microsoft Office\root\Office16\VISIO.EXE',
                'C:\Program Files (x86)\Microsoft Office\root\Office16\VISIO.EXE'
            )
        }
    )

    $missing = @()

    foreach ($component in $components) {
        $installed = $false

        foreach ($path in $component.Paths) {
            if (Test-Path $path) {
                $installed = $true
                break
            }
        }

        if (-not $installed) {
            $missing += $component.Name
        }
    }

    return @($missing)
}

function Remove-RecoveredTaskFailure {
    param(
        [string[]]$FailedTasks,
        [string]$TaskName
    )

    return @(
        $FailedTasks |
            Where-Object {
                [string]$_ -ne $TaskName
            }
    )
}

function Set-InstallerExecutionState {
    param(
        [string]$Status,
        [string]$Message = '',
        [int]$ExitCode = -999999,
        [switch]$Completed
    )

    $baseKey = $null
    $registryKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )

        $registryKey = $baseKey.CreateSubKey(
            'SOFTWARE\ImagemTI\Instalador',
            $true
        )

        $values = @{
            Status = $Status
            LastMessage = $Message
            LastRunTime = (Get-Date -Format o)
            LastRunVersion = $PackageVersion
        }

        if ($ExitCode -ne -999999) {
            $values['LastExitCode'] = [string]$ExitCode
        }

        if ($Completed) {
            $values['CompletedVersion'] = $PackageVersion
            $values['CompletedTime'] = (Get-Date -Format o)
        }

        foreach ($name in $values.Keys) {
            $registryKey.SetValue(
                $name,
                [string]$values[$name],
                [Microsoft.Win32.RegistryValueKind]::String
            )
        }
    }
    catch {
        Write-Host (
            'Nao foi possivel atualizar o estado no registro: ' +
            $_.Exception.Message
        )
    }
    finally {
        if ($null -ne $registryKey) {
            $registryKey.Dispose()
        }

        if ($null -ne $baseKey) {
            $baseKey.Dispose()
        }
    }
}

$context = New-InstallerContext `
    -Mode $Mode `
    -RepositoryRoot $RepositoryRoot `
    -MaxInstallAttempts $MaxInstallAttempts `
    -PackageVersion $PackageVersion

Remove-Item `
    -Path $context.FailedFlagPath `
    -Force `
    -ErrorAction SilentlyContinue

Set-InstallerExecutionState `
    -Status 'Running' `
    -Message "Executor iniciado. Modo: $Mode."
$failedTasks = @()

Write-InstallerLog -Context $context -Message "Inicio da instalacao. Versao: $PackageVersion. Modo: $Mode. Usuario: $env:USERNAME. Computador: $env:COMPUTERNAME. IsIntune: $($context.IsIntune). IsScheduled: $($context.IsScheduled). Maximo de tentativas para apps: $MaxInstallAttempts."

try {
    Assert-UsuarioPermitido -Context $context -BlockedUserNames @('Imagem')
} catch {
    Write-InstallerLog -Context $context -Message "Execucao bloqueada por usuario nao permitido: $($_.Exception.Message)" -Level Error
    Add-InstallerResult -Context $context -Type 'preflight' -Name 'Assert-UsuarioPermitido' -Status 'Blocked' -Message $_.Exception.Message
    Write-InstallerSummary -Context $context -FinalStatus 'BlockedUser' -FailedTasks @('Assert-UsuarioPermitido')
    Set-Content -Path $context.FailedFlagPath -Value (Get-Date -Format o) -Encoding ASCII -Force
    Set-InstallerExecutionState -Status 'BlockedUser' -Message $_.Exception.Message -ExitCode 2
    exit 2
}

try {
    Assert-Administrator
} catch {
    Write-InstallerLog -Context $context -Message "Falha critica de permissao: $($_.Exception.Message)" -Level Error
    Add-InstallerResult -Context $context -Type 'preflight' -Name 'Assert-Administrator' -Status 'Failed' -Message $_.Exception.Message
    Write-InstallerSummary -Context $context -FinalStatus 'Failed' -FailedTasks @('Assert-Administrator')
    Set-Content -Path $context.FailedFlagPath -Value (Get-Date -Format o) -Encoding ASCII -Force
    Set-InstallerExecutionState -Status 'Failed' -Message $_.Exception.Message -ExitCode 1
    exit 1
}

$profileName = $Mode.ToLowerInvariant()
$profilePath = Join-Path $RepositoryRoot "20-Configuracoes\Perfis\$profileName.json"

try {
    if (-not (Test-Path $profilePath)) { throw "Perfil nao encontrado: $profilePath" }
    $profile = Get-Content -Path $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $context.MaxInstallAttempts = Get-ProfileIntValue -Profile $profile -Names @('maximoTentativasInstalacao','maxInstallAttempts') -Default $context.MaxInstallAttempts
    Write-InstallerLog -Context $context -Message "Maximo de tentativas definido pelo perfil: $($context.MaxInstallAttempts)."
} catch {
    Write-InstallerLog -Context $context -Message "Falha critica ao carregar perfil: $($_.Exception.Message)" -Level Error
    Add-InstallerResult -Context $context -Type 'profile' -Name $profileName -Status 'Failed' -Message $_.Exception.Message
    Write-InstallerSummary -Context $context -FinalStatus 'Failed' -FailedTasks @('LoadProfile')
    Set-Content -Path $context.FailedFlagPath -Value (Get-Date -Format o) -Encoding ASCII -Force
    Set-InstallerExecutionState -Status 'Failed' -Message $_.Exception.Message -ExitCode 1
    exit 1
}

foreach ($app in @(Get-ProfileRequiredAplicativos -Profile $profile)) {
    Register-RequiredApp -Context $context -Name $app
}

try {
    $initialApps = @(Get-AppsPlanejadosPorContexto -Context $context -Profile $profile)

    foreach ($plannedApp in $initialApps) {
        Register-RequiredApp -Context $context -Name $plannedApp
    }

    Write-InstallerLog -Context $context -Message "Aplicativos registrados para verificacao final: $($initialApps -join ', ')"
    Invoke-InitialAppVerification -Context $context -AppNames $initialApps
} catch {
    Write-InstallerLog -Context $context -Message "Verificacao inicial de aplicativos falhou, mas o instalador continuara: $($_.Exception.Message)" -Level Warning
}

$profileTasks = @(Get-ProfileTaskList -Profile $profile)
foreach ($taskName in $profileTasks) {
    $task = [string]$taskName
    try {
        Invoke-InstallerTask -Context $context -TaskName $task
        Add-InstallerResult -Context $context -Type 'task' -Name $task -Status 'Success' -Message 'Tarefa executada sem erro fatal.'
        Write-InstallerLog -Context $context -Message "Tarefa concluida: $task" -Level Success
    } catch {
        $message = $_.Exception.Message
        $failedTasks += $task
        Add-InstallerResult -Context $context -Type 'task' -Name $task -Status 'Failed' -Message $message
        $isCriticalIntuneBarrier = (
            $context.IsIntune -and
            $task -eq '10-Seguranca-InstalarAgentesEmpresa'
        )

        if ($isCriticalIntuneBarrier) {
            Write-InstallerLog `
                -Context $context `
                -Message (
                    "BARREIRA CRITICA DO INTUNE FALHOU: $message. " +
                    "As demais tarefas nao serao executadas nesta rodada."
                ) `
                -Level Error

            if ($_.ScriptStackTrace) {
                Write-InstallerLog `
                    -Context $context `
                    -Message $_.ScriptStackTrace `
                    -Level Error
            }

            Write-InstallerSummary `
                -Context $context `
                -FinalStatus 'Failed' `
                -FailedTasks @($failedTasks)

            Set-Content `
                -Path $context.FailedFlagPath `
                -Value (Get-Date -Format o) `
                -Encoding ASCII `
                -Force

            Set-InstallerExecutionState `
                -Status 'Failed' `
                -Message "Barreira critica: $message" `
                -ExitCode 1

            exit 1
        }

        Write-InstallerLog `
            -Context $context `
            -Message (
                "Tarefa falhou, mas o instalador continuara: " +
                "$task -> $message"
            ) `
            -Level Error

        if ($_.ScriptStackTrace) {
            Write-InstallerLog `
                -Context $context `
                -Message $_.ScriptStackTrace `
                -Level Error
        }
    }
}

$missingAplicativos = @(
    Invoke-FinalAppVerification `
        -Context $context `
        -RequiredAplicativos @(
            Get-RequiredAplicativos -Context $context
        )
)

if ($missingAplicativos.Count -eq 0) {
    foreach ($applicationTaskName in @(
        '10-Seguranca-InstalarAgentesEmpresa',
        '50-Aplicativos-InstalarBase'
    )) {
        if ($failedTasks -contains $applicationTaskName) {
            Write-InstallerLog `
                -Context $context `
                -Message (
                    "A tarefa '$applicationTaskName' falhou inicialmente, " +
                    "mas todos os aplicativos foram recuperados na " +
                    "auditoria final."
                ) `
                -Level Success

            $failedTasks = @(
                Remove-RecoveredTaskFailure `
                    -FailedTasks $failedTasks `
                    -TaskName $applicationTaskName
            )
        }
    }
}

$officeWasPlanned = (
    $profileTasks -contains
    '51-Aplicativos-InstalarOffice'
)

$missingOffice = @()

if ($officeWasPlanned) {
    $missingOffice = @(
        Get-OfficeSuiteMissingComponents
    )

    if ($missingOffice.Count -gt 0) {
        Write-InstallerLog `
            -Context $context `
            -Message (
                "AUDITORIA FINAL DO OFFICE encontrou ausentes: " +
                "$($missingOffice -join ', '). A tarefa sera " +
                "executada novamente."
            ) `
            -Level Warning

        try {
            Invoke-InstallerTask `
                -Context $context `
                -TaskName '51-Aplicativos-InstalarOffice'

            $missingOffice = @(
                Get-OfficeSuiteMissingComponents
            )

            if ($missingOffice.Count -eq 0) {
                Write-InstallerLog `
                    -Context $context `
                    -Message (
                        'AUDITORIA FINAL DO OFFICE: Microsoft 365, ' +
                        'Project e Visio recuperados.'
                    ) `
                    -Level Success

                $failedTasks = @(
                    Remove-RecoveredTaskFailure `
                        -FailedTasks $failedTasks `
                        -TaskName '51-Aplicativos-InstalarOffice'
                )
            }
        }
        catch {
            Write-InstallerLog `
                -Context $context `
                -Message (
                    "Nova tentativa final do Office falhou: " +
                    "$($_.Exception.Message)"
                ) `
                -Level Error
        }
    }
    else {
        Write-InstallerLog `
            -Context $context `
            -Message (
                'AUDITORIA FINAL DO OFFICE: Microsoft 365, ' +
                'Project e Visio instalados.'
            ) `
            -Level Success

        $failedTasks = @(
            Remove-RecoveredTaskFailure `
                -FailedTasks $failedTasks `
                -TaskName '51-Aplicativos-InstalarOffice'
        )
    }
}

$missingFinal = @(
    @($missingAplicativos) +
    @($missingOffice) |
        ForEach-Object {
            [string]$_
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique
)

$hasFailure = (
    $failedTasks.Count -gt 0 -or
    $missingFinal.Count -gt 0
)

if ($hasFailure) {
    $missingAppArray = @(
        $missingFinal |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    $failedTaskArray = @(
        $failedTasks |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    $finalMessage = "Instalacao finalizada COM PENDENCIAS. Tarefas com erro: $($failedTaskArray -join ', '). Aplicativos pendentes: $($missingAppArray -join ', ')."
    Write-InstallerLog -Context $context -Message $finalMessage -Level Error
    Write-InstallerSummary -Context $context -FinalStatus 'CompletedWithErrors' -MissingAplicativos $missingAppArray -FailedTasks $failedTaskArray
    Invoke-AvisoManualFinalizacao -Context $context -Status 'Pendencias' -MissingAplicativos $missingAppArray -FailedTasks $failedTaskArray
    Set-Content -Path $context.FailedFlagPath -Value (Get-Date -Format o) -Encoding ASCII -Force

    if ($context.IsScheduled) {
        Write-InstallerLog -Context $context -Message 'A tarefa persistente permanece ativa para novas execucoes.' -Level Warning
    }

    Set-InstallerExecutionState `
        -Status 'CompletedWithErrors' `
        -Message $finalMessage `
        -ExitCode 1

    exit 1
}

Remove-Item -Path $context.FailedFlagPath -Force -ErrorAction SilentlyContinue
Set-Content -Path $context.FlagPath -Value (Get-Date -Format o) -Encoding ASCII -Force

if ($Mode -eq 'IntuneCritical') {
    Set-InstallerExecutionState `
        -Status 'CriticalCompleted' `
        -Message 'Atlas, Journey, Sophos e Guardian confirmados.' `
        -ExitCode 0

    Write-InstallerSummary `
        -Context $context `
        -FinalStatus 'Success'

    Write-InstallerLog `
        -Context $context `
        -Message (
            'Fase critica concluida com sucesso. O executor persistente ' +
            'aguardara o desktop para iniciar as demais tarefas.'
        ) `
        -Level Success

    exit 0
}

if ($context.IsScheduled) {
    $completionContent = @(
        "Version=$PackageVersion",
        "Date=$(Get-Date -Format o)"
    ) -join [Environment]::NewLine

    Set-Content `
        -Path (Join-Path $context.FlagDirectory 'intune_scheduled_completed.flag') `
        -Value $completionContent `
        -Encoding ASCII `
        -Force
    Write-InstallerLog `
        -Context $context `
        -Message (
            'Conclusao registrada. A tarefa persistente sera desativada ' +
            'pelo executor do pacote Intune apos confirmar o codigo 0.'
        ) `
        -Level Success
}

Set-InstallerExecutionState `
    -Status 'Completed' `
    -Message 'Instalacao concluida com sucesso.' `
    -ExitCode 0 `
    -Completed

Write-InstallerSummary -Context $context -FinalStatus 'Success'
Invoke-AvisoManualFinalizacao -Context $context -Status 'Sucesso'
Write-InstallerLog -Context $context -Message 'Instalacao concluida com sucesso.' -Level Success
exit 0
