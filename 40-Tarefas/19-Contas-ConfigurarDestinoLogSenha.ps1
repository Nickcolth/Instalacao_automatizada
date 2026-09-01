param($Context)

$ErrorActionPreference = 'Stop'

$configPath = Join-Path `
    $Context.RepositoryRoot `
    '60-Segredos\topdesk-config.json'

$novoDestino = '\\fileserver\SDK\Softwares\logsenha'

if (-not (Test-Path $configPath)) {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            'Configuracao do TOPdesk nao encontrada para ajustar o ' +
            "destino do log de senha. Caminho esperado: $configPath"
        ) `
        -Level Warning

    return
}

try {
    $config = Get-Content `
        -Path $configPath `
        -Raw `
        -Encoding UTF8 `
        -ErrorAction Stop |
        ConvertFrom-Json

    if ($config.PSObject.Properties.Name -contains 'networkBackupPath') {
        $config.networkBackupPath = $novoDestino
    }
    else {
        $config |
            Add-Member `
                -MemberType NoteProperty `
                -Name 'networkBackupPath' `
                -Value $novoDestino
    }

    $config |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -Path $configPath `
            -Encoding UTF8 `
            -Force `
            -ErrorAction Stop

    Write-InstallerLog `
        -Context $Context `
        -Message (
            'Destino do log de senha configurado para: ' +
            $novoDestino
        ) `
        -Level Success
}
catch {
    throw (
        'Falha ao configurar o destino do log de senha: ' +
        $_.Exception.Message
    )
}
