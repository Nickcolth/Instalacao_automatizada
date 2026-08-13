param($Context)

function Get-AgentDisplayName {
    param(
        $Context,
        [string]$Name
    )

    $manifest = Get-AppManifest `
        -Context $Context `
        -Name $Name

    if (
        $manifest.PSObject.Properties.Name -contains 'displayName' -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$manifest.displayName
        )
    ) {
        return [string]$manifest.displayName
    }

    return $Name
}

function Invoke-ManualAppAsSystem {
    param(
        $Context,
        [string]$Name,
        [int]$Attempt
    )

    $displayName = Get-AgentDisplayName `
        -Context $Context `
        -Name $Name

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

        if ($identity.IsSystem) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "$displayName ja esta sendo executado como SYSTEM. " +
                    'A instalacao seguira diretamente.'
                ) `
                -Level Success

            return [bool](
                Install-AppFromManifest `
                    -Context $Context `
                    -Name $Name `
                    -Attempt $Attempt
            )
        }
    }
    catch {}

    $helperPath = Join-Path `
        $Context.RepositoryRoot `
        '40-Tarefas\11-Sistema-InstalarAplicativoComoSystem.ps1'

    if (-not (Test-Path $helperPath)) {
        throw (
            'Executor SYSTEM auxiliar nao encontrado: ' +
            $helperPath
        )
    }

    $safeName = $Name -replace '[^A-Za-z0-9_-]', '_'
    $runId = [guid]::NewGuid().ToString('N')
    $taskPath = '\ImagemTI\'
    $taskName = "Manual-System-$safeName-$runId"
    $resultPath = Join-Path `
        $Context.ReportDirectory `
        "manual_system_${safeName}_${runId}.json"

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $helperPath),
        '-RepositoryRoot', ('"{0}"' -f $Context.RepositoryRoot),
        '-AppName', ('"{0}"' -f $Name),
        '-PackageVersion', ('"{0}"' -f $Context.PackageVersion),
        '-Attempt', [string]$Attempt,
        '-MaxInstallAttempts', [string]$Context.MaxInstallAttempts,
        '-ResultPath', ('"{0}"' -f $resultPath)
    ) -join ' '

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument $arguments

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "$displayName requer contexto SYSTEM na execucao manual. " +
            'Criando tarefa temporaria como NT AUTHORITY\SYSTEM. '
        ) `
        -Level Warning

    try {
        Register-ScheduledTask `
            -TaskPath $taskPath `
            -TaskName $taskName `
            -Action $action `
            -Principal $principal `
            -Settings $settings `
            -Description (
                "Instalacao manual temporaria de $displayName como SYSTEM."
            ) `
            -Force |
            Out-Null

        Start-ScheduledTask `
            -TaskPath $taskPath `
            -TaskName $taskName

        $timeoutSeconds = 3600
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()

        while (-not (Test-Path $resultPath)) {
            if (
                $stopwatch.Elapsed.TotalSeconds -ge
                $timeoutSeconds
            ) {
                throw (
                    "$displayName excedeu $timeoutSeconds segundos " +
                    'na execucao temporaria como SYSTEM.'
                )
            }

            Start-Sleep -Seconds 2
        }

        $stopwatch.Stop()

        $systemResult = Get-Content `
            -Path $resultPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json

        if (-not [bool]$systemResult.Success) {
            throw (
                "$displayName falhou como SYSTEM. Identidade: " +
                "$($systemResult.Identity). Erro: " +
                "$($systemResult.Message)"
            )
        }

        Write-InstallerLog `
            -Context $Context `
            -Message (
                "$displayName concluido como SYSTEM em " +
                "$([math]::Round($stopwatch.Elapsed.TotalMinutes, 1)) " +
                "minuto(s). Identidade confirmada: " +
                "$($systemResult.Identity). Log SYSTEM: " +
                "$($systemResult.LogPath)"
            ) `
            -Level Success

        return $true
    }
    finally {
        try {
            Stop-ScheduledTask `
                -TaskPath $taskPath `
                -TaskName $taskName `
                -ErrorAction SilentlyContinue
        }
        catch {}

        try {
            Unregister-ScheduledTask `
                -TaskPath $taskPath `
                -TaskName $taskName `
                -Confirm:$false `
                -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Set-RemainingManualAgentsBlocked {
    param(
        $Context,
        [string[]]$Names,
        [string]$Reason
    )

    foreach ($blockedName in @($Names)) {
        for (
            $blockedAttempt = 1;
            $blockedAttempt -le $Context.MaxInstallAttempts;
            $blockedAttempt++
        ) {
            Add-InstallerResult `
                -Context $Context `
                -Type 'app' `
                -Name $blockedName `
                -Status 'Blocked' `
                -Attempt $blockedAttempt `
                -Message $Reason
        }
    }
}

$empresaApps = Get-EmpresaAppsPorNomeEquipamento `
    -Context $Context

if (-not $empresaApps.Reconhecida) {
    throw (
        "Nome do equipamento nao reconhecido: " +
        "$env:COMPUTERNAME. Nao e seguro escolher " +
        "automaticamente Atlas e Sophos."
    )
}

$apps = @(
    $empresaApps.Aplicativos |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique
)

$atlasSelecionados = @(
    $apps |
        Where-Object {
            $_ -like 'atlas-*'
        }
)

$sophosSelecionados = @(
    $apps |
        Where-Object {
            $_ -like 'sophos-*'
        }
)

if ($atlasSelecionados.Count -ne 1) {
    throw (
        "Era esperado exatamente um Atlas para a empresa " +
        "'$($empresaApps.Nome)', mas foram encontrados: " +
        "$($atlasSelecionados -join ', ')."
    )
}

if ($sophosSelecionados.Count -ne 1) {
    throw (
        "Era esperado exatamente um Sophos para a empresa " +
        "'$($empresaApps.Nome)', mas foram encontrados: " +
        "$($sophosSelecionados -join ', ')."
    )
}

$atlas = [string]$atlasSelecionados[0]
$sophos = [string]$sophosSelecionados[0]
$ordemCritica = @(
    $atlas,
    'journey',
    $sophos,
    'guardian'
)

if ($Context.IsIntune) {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            "ORDEM CRITICA DO INTUNE para '$($empresaApps.Nome)': " +
            "$($ordemCritica -join ' -> '). Nenhuma outra etapa " +
            "sera executada antes da confirmacao dos quatro agentes."
        ) `
        -Level Warning

    foreach ($app in $ordemCritica) {
        Register-RequiredApp `
            -Context $Context `
            -Name $app

        $displayName = Get-AgentDisplayName `
            -Context $Context `
            -Name $app

        if (
            Test-AppInstalledByName `
                -Context $Context `
                -Name $app
        ) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "BARREIRA INTUNE: $displayName ja esta instalado. " +
                    "Prosseguindo para o proximo item da ordem."
                ) `
                -Level Success

            continue
        }

        $instalado = $false

        for (
            $tentativa = 1;
            $tentativa -le $Context.MaxInstallAttempts;
            $tentativa++
        ) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "BARREIRA INTUNE: instalando $displayName. " +
                    "Tentativa $tentativa de " +
                    "$($Context.MaxInstallAttempts)."
                ) `
                -Level Warning

            try {
                $null = Install-AppFromManifest `
                    -Context $Context `
                    -Name $app `
                    -Attempt $tentativa
            }
            catch {
                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        "BARREIRA INTUNE: erro na tentativa " +
                        "$tentativa de ${displayName}: " +
                        "$($_.Exception.Message)"
                    ) `
                    -Level Error
            }

            if (
                Test-AppInstalledByName `
                    -Context $Context `
                    -Name $app
            ) {
                $instalado = $true

                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        "BARREIRA INTUNE: $displayName instalado e " +
                        "confirmado. Prosseguindo para o proximo item."
                    ) `
                    -Level Success

                break
            }

            if (
                $tentativa -lt
                $Context.MaxInstallAttempts
            ) {
                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        "BARREIRA INTUNE: $displayName ainda nao foi " +
                        "detectado. Uma nova tentativa sera executada."
                    ) `
                    -Level Warning

                Start-Sleep -Seconds 15
            }
        }

        if (-not $instalado) {
            throw (
                "BARREIRA CRITICA DO INTUNE: $displayName nao foi " +
                "instalado depois de " +
                "$($Context.MaxInstallAttempts) tentativas. " +
                "O instalador sera interrompido antes das demais " +
                "tarefas. A execucao persistente do Intune tentara " +
                "novamente mais tarde."
            )
        }
    }

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "BARREIRA INTUNE CONCLUIDA: Atlas, Journey, Sophos e " +
            "Guardian foram instalados e confirmados na ordem exigida."
        ) `
        -Level Success

    return
}

Write-InstallerLog `
    -Context $Context `
    -Message (
        "ORDEM DOS AGENTES NA EXECUCAO MANUAL para " +
        "'$($empresaApps.Nome)': $($ordemCritica -join ' -> '). " +
        'Atlas/MoreMesh e Journey serao instalados como SYSTEM.'
    ) `
    -Level Warning

for (
    $index = 0;
    $index -lt $ordemCritica.Count;
    $index++
) {
    $app = [string]$ordemCritica[$index]
    $displayName = Get-AgentDisplayName `
        -Context $Context `
        -Name $app

    Register-RequiredApp `
        -Context $Context `
        -Name $app

    if (
        Test-AppInstalledByName `
            -Context $Context `
            -Name $app
    ) {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                "BARREIRA MANUAL: $displayName ja esta instalado. " +
                'Prosseguindo para o proximo agente.'
            ) `
            -Level Success

        continue
    }

    $requiresSystem = (
        $app -eq $atlas -or
        $app -eq 'journey'
    )
    $installed = $false

    for (
        $attempt = 1;
        $attempt -le $Context.MaxInstallAttempts;
        $attempt++
    ) {
        try {
            if ($requiresSystem) {
                $null = Invoke-ManualAppAsSystem `
                    -Context $Context `
                    -Name $app `
                    -Attempt $attempt
            }
            else {
                $null = Install-AppFromManifest `
                    -Context $Context `
                    -Name $app `
                    -Attempt $attempt
            }
        }
        catch {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "BARREIRA MANUAL: falha na tentativa $attempt " +
                    "de ${displayName}: $($_.Exception.Message)"
                ) `
                -Level Error

            Add-InstallerResult `
                -Context $Context `
                -Type 'app' `
                -Name $app `
                -Status 'Failed' `
                -Attempt $attempt `
                -Message $_.Exception.Message
        }

        if (
            Test-AppInstalledByName `
                -Context $Context `
                -Name $app
        ) {
            $installed = $true

            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "BARREIRA MANUAL: $displayName instalado e " +
                    'confirmado. Prosseguindo para o proximo agente.'
                ) `
                -Level Success

            break
        }

        if ($attempt -lt $Context.MaxInstallAttempts) {
            Start-Sleep -Seconds 15
        }
    }

    if (-not $installed) {
        $remainingApps = @()

        if ($index + 1 -lt $ordemCritica.Count) {
            $remainingApps = @(
                $ordemCritica[($index + 1)..($ordemCritica.Count - 1)]
            )
        }

        $blockReason = (
            "Bloqueado porque o agente anterior '$displayName' nao " +
            'foi confirmado. A ordem Atlas -> Journey -> Sophos -> ' +
            'Guardian nao pode ser quebrada.'
        )

        Set-RemainingManualAgentsBlocked `
            -Context $Context `
            -Names $remainingApps `
            -Reason $blockReason

        throw (
            "BARREIRA MANUAL: $displayName nao foi instalado depois " +
            "de $($Context.MaxInstallAttempts) tentativas. Os agentes " +
            'seguintes foram bloqueados para impedir que o Sophos seja ' +
            'instalado antes de Atlas/MoreMesh e Journey.'
        )
    }
}

Write-InstallerLog `
    -Context $Context `
    -Message (
        'BARREIRA MANUAL CONCLUIDA: Atlas/MoreMesh e Journey foram ' +
        'executados como SYSTEM e todos os agentes foram confirmados ' +
        'na ordem Atlas -> Journey -> Sophos -> Guardian.'
    ) `
    -Level Success
