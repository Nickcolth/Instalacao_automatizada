param($Context)

function global:Invoke-ManutencaoFinal {
    param($Context)

    if ($null -eq $Context) { return }

    $winget = Get-WingetExecutable
    if ([string]::IsNullOrWhiteSpace($winget)) {
        Write-InstallerLog -Context $Context -Message 'Atualizacao final ignorada: winget nao foi encontrado.' -Level Warning
    }
    else {
        try {
            $wingetExitCode = Invoke-WithTimeout `
                -Context $Context `
                -FilePath $winget `
                -ArgumentList 'upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' `
                -TimeoutSeconds 7200 `
                -Name 'atualizacao final de aplicativos pelo winget'

            if ($wingetExitCode -eq 0) {
                Write-InstallerLog -Context $Context -Message 'Atualizacao final de aplicativos concluida.' -Level Success
            }
            else {
                Write-InstallerLog -Context $Context -Message "Winget upgrade finalizou com codigo $wingetExitCode; a finalizacao continuara normalmente." -Level Warning
            }
        }
        catch {
            Write-InstallerLog -Context $Context -Message "Falha na atualizacao final pelo winget; a finalizacao continuara normalmente: $($_.Exception.Message)" -Level Warning
        }
    }

    if ($Context.Mode -ne 'Manual') { return }

    try {
        $gpupdateExitCode = Invoke-WithTimeout `
            -Context $Context `
            -FilePath (Join-Path $env:SystemRoot 'System32\gpupdate.exe') `
            -ArgumentList '/force /wait:120' `
            -TimeoutSeconds 180 `
            -Name 'atualizacao final das politicas de grupo'

        if ($gpupdateExitCode -eq 0) {
            Write-InstallerLog -Context $Context -Message 'Politicas de grupo atualizadas sem solicitar logoff ou reinicializacao.' -Level Success
        }
        else {
            Write-InstallerLog -Context $Context -Message "Gpupdate finalizou com codigo $gpupdateExitCode; nenhum logoff ou reinicio foi solicitado e a finalizacao continuara normalmente." -Level Warning
        }
    }
    catch {
        Write-InstallerLog -Context $Context -Message "Gpupdate excedeu o limite ou falhou; nenhum logoff ou reinicio foi solicitado e a finalizacao continuara normalmente: $($_.Exception.Message)" -Level Warning
    }
}

Write-InstallerLog -Context $Context -Message 'Etapa manual final registrada. O aviso visual/sonoro sera exibido somente no encerramento real do modo Manual, apos a verificacao final.' -Level Warning
Write-InstallerLog -Context $Context -Message 'Confira OneDrive, Outlook, VPN, BitLocker e remova/valide permissoes administrativas conforme o procedimento interno.' -Level Warning
Write-InstallerLog -Context $Context -Message 'As atualizacoes finais de aplicativos e politicas serao executadas automaticamente antes do aviso de encerramento.' -Level Warning
Write-InstallerLog -Context $Context -Message 'Gpupdate limitado a 120 segundos de espera e 180 segundos de timeout total; a finalizacao continua mesmo se ele nao responder.' -Level Warning
Write-InstallerLog -Context $Context -Message 'Confirme no TOPdesk os dados de senha/status e inventario; depois remova logs sensiveis conforme o procedimento interno.' -Level Warning
