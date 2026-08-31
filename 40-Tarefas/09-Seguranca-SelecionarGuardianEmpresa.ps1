param($Context)

$ErrorActionPreference = 'Stop'

$computerName = [string]$env:COMPUTERNAME
$computerName = $computerName.ToUpperInvariant()

Write-InstallerLog `
    -Context $Context `
    -Message (
        "Guardian GPI padrao selecionado para $computerName. " +
        'Todas as empresas utilizam a versao definida no manifesto guardian.json.'
    ) `
    -Level Success
