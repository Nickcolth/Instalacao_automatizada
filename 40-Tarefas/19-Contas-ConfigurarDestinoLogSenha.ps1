param($Context)

$ErrorActionPreference = 'Stop'

$configPath = Join-Path `
    $Context.RepositoryRoot `
    '60-Segredos\Znuny-Producao.config.json'

$novoDestino = '\\fileserver\SDK\Softwares\Instalacao_automatizada\logsenha'

if (-not (Test-Path $configPath)) {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            'Copia privada do Znuny ausente; tarefas 20/21 usam o JSON UNC e o destino padrao de backup.'
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
    Write-InstallerLog -Context $Context -Message 'Falha ao configurar o destino do log de senha. Detalhes omitidos; preparacao continua.' -Level Warning
}
