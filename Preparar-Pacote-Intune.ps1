[CmdletBinding()]
param(
    [string]$OutputDirectory = 'C:\Intune\Pacote_Intune_Autopilot',
    [string]$SecretsSource = ''
)

$ErrorActionPreference = 'Stop'
$sourceOutput = Join-Path $OutputDirectory 'Fonte'
$secretsOutput = Join-Path $sourceOutput 'Segredos'
$toolsRoot = Join-Path $PSScriptRoot '85-Ferramentas\Intune'

$requiredFiles = @(
    'VERSION.txt',
    'Instalar-Intune.ps1',
    '00-Inicializacao\Executar-InstalacaoPersistente.ps1',
    '70-Deteccao\Detectar-PreparoIntune.ps1',
    '85-Ferramentas\Intune\Instalar.cmd',
    '85-Ferramentas\Intune\Desinstalar.cmd',
    '85-Ferramentas\Intune\Desinstalar-Intune.ps1',
    '85-Ferramentas\Intune\Detectar-InstalacaoCompleta.ps1'
)

foreach ($relativePath in $requiredFiles) {
    $sourcePath = Join-Path $PSScriptRoot $relativePath

    if (-not (Test-Path $sourcePath)) {
        throw "Arquivo obrigatorio ausente: $sourcePath"
    }
}

if (Test-Path $OutputDirectory) {
    Remove-Item -Path $OutputDirectory -Recurse -Force
}

New-Item `
    -Path $OutputDirectory, $sourceOutput `
    -ItemType Directory `
    -Force |
    Out-Null

Copy-Item `
    -Path (Join-Path $PSScriptRoot 'VERSION.txt') `
    -Destination (Join-Path $sourceOutput 'VERSION.txt') `
    -Force

Copy-Item `
    -Path (Join-Path $toolsRoot 'Instalar.cmd') `
    -Destination (Join-Path $sourceOutput 'Instalar.cmd') `
    -Force

Copy-Item `
    -Path (Join-Path $PSScriptRoot 'Instalar-Intune.ps1') `
    -Destination (Join-Path $sourceOutput 'Instalar-Intune.ps1') `
    -Force

Copy-Item `
    -Path (
        Join-Path `
            $PSScriptRoot `
            '00-Inicializacao\Executar-InstalacaoPersistente.ps1'
    ) `
    -Destination (
        Join-Path $sourceOutput 'Executar-InstalacaoPersistente.ps1'
    ) `
    -Force

Copy-Item `
    -Path (Join-Path $toolsRoot 'Desinstalar.cmd') `
    -Destination (Join-Path $sourceOutput 'Desinstalar.cmd') `
    -Force

Copy-Item `
    -Path (Join-Path $toolsRoot 'Desinstalar-Intune.ps1') `
    -Destination (Join-Path $sourceOutput 'Desinstalar-Intune.ps1') `
    -Force

Copy-Item `
    -Path (
        Join-Path `
            $PSScriptRoot `
            '70-Deteccao\Detectar-PreparoIntune.ps1'
    ) `
    -Destination (Join-Path $sourceOutput 'Detectar-PreparoIntune.ps1') `
    -Force

Copy-Item `
    -Path (Join-Path $toolsRoot 'Detectar-InstalacaoCompleta.ps1') `
    -Destination (Join-Path $sourceOutput 'Detectar-InstalacaoCompleta.ps1') `
    -Force

if (-not [string]::IsNullOrWhiteSpace($SecretsSource)) {
    if (-not (Test-Path $SecretsSource)) {
        throw "Pasta de segredos nao encontrada: $SecretsSource"
    }

    New-Item -Path $secretsOutput -ItemType Directory -Force | Out-Null

    Copy-Item `
        -Path (Join-Path $SecretsSource '*') `
        -Destination $secretsOutput `
        -Recurse `
        -Force
}

Write-Host 'Fonte do pacote Intune criada:' -ForegroundColor Green
Write-Host $sourceOutput
