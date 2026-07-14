param($Context)

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

if ($Context.IsIntune) {
    $ordemCritica = @(
        $atlas,
        'journey',
        $sophos,
        'guardian'
    )

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

        $manifest = Get-AppManifest `
            -Context $Context `
            -Name $app

        $displayName = if (
            $manifest.PSObject.Properties.Name -contains
            'displayName' -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$manifest.displayName
            )
        ) {
            [string]$manifest.displayName
        }
        else {
            $app
        }

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
        "Agentes de seguranca/corporativos selecionados para " +
        "'$($empresaApps.Nome)': $($apps -join ', ')"
    )

$resultado = Invoke-AppInstallSet `
    -Context $Context `
    -AppNames $apps `
    -StageName 'Seguranca corporativa'

if (-not $resultado) {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            "A etapa de seguranca terminou com pendencias. " +
            "A verificacao final tentara novamente."
        ) `
        -Level Warning
}

if (
    -not (
        Test-AppInstalledByName `
            -Context $Context `
            -Name $sophos
    )
) {
    throw (
        "Sophos nao foi detectado apos a etapa de seguranca: " +
        "$sophos"
    )
}

Write-InstallerLog `
    -Context $Context `
    -Message "Sophos confirmado no equipamento: $sophos" `
    -Level Success
