param($Context)

$ErrorActionPreference = 'Stop'

$computerName = [string]$env:COMPUTERNAME
$computerName = $computerName.ToUpperInvariant()

$usarGuardianGpi = (
    $computerName -like 'NOTEGESTAO*' -or
    $computerName -like 'NOTEGEO*'
)

if (-not $usarGuardianGpi) {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            "Guardian antigo mantido para o equipamento " +
            "$computerName."
        ) `
        -Level Success

    return
}

$manifestPath = Join-Path `
    $Context.RepositoryRoot `
    '20-Configuracoes\Aplicativos\guardian.json'

$linkPath = Join-Path `
    $Context.RepositoryRoot `
    '30-Links\guardian\padrao.txt'

$key = 'GPI-2MPQ-Y2P2-2DJV-B27U'
$url = (
    'https://pub-98d17cb00ebd4b1f87c6dadf75222ea6.r2.dev/' +
    'guardian-suite/GuardianSetup_4.1.56_GPI.exe'
)

$manifest = [ordered]@{
    displayName = 'Guardian Suite GPI 4.1.56'
    fileName = 'GuardianSetup_4.1.56_GPI.exe'
    silentArgs = (
        '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /KEY=' + $key
    )
    detectionPaths = @(
        'C:\Program Files (x86)\MoreApps\GuardianDesk\GuardianDesk.exe',
        'C:\Program Files (x86)\MoreAplicativos\GuardianDesk\GuardianDesk.exe',
        'C:\Program Files\MoreApps\GuardianDesk\GuardianDesk.exe',
        'C:\Program Files\MoreAplicativos\GuardianDesk\GuardianDesk.exe'
    )
    successExitCodes = @(
        0,
        3010
    )
    downloadTimeoutSeconds = 900
    installTimeoutSeconds = 3600
    detectionRegistryDisplayNames = @(
        'GuardianDesk*',
        'Guardian Desk*'
    )
    postDetectionTimeoutSeconds = 180
    packageManagerOrder = @(
        'direct'
    )
}

try {
    if (-not (Test-Path $manifestPath)) {
        throw "Manifesto original do Guardian nao encontrado: $manifestPath"
    }

    $linkDirectory = Split-Path -Path $linkPath -Parent

    New-Item `
        -Path $linkDirectory `
        -ItemType Directory `
        -Force |
        Out-Null

    $manifest |
        ConvertTo-Json -Depth 6 |
        Set-Content `
            -Path $manifestPath `
            -Encoding UTF8 `
            -Force

    Set-Content `
        -Path $linkPath `
        -Value $url `
        -Encoding ASCII `
        -Force

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "Guardian GPI 4.1.56 selecionado automaticamente para " +
            "$computerName. O Guardian antigo nao sera usado nesta " +
            'execucao.'
        ) `
        -Level Success
}
catch {
    Remove-Item `
        -Path $manifestPath `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -Path $linkPath `
        -Force `
        -ErrorAction SilentlyContinue

    throw (
        'Falha ao selecionar o Guardian GPI para Atmis/GEO. ' +
        'O Guardian antigo foi bloqueado para esta execucao. Erro: ' +
        $_.Exception.Message
    )
}
