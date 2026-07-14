[CmdletBinding()]
param(
    [string]$Raiz = $PSScriptRoot,
    [string]$NomeComputador = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

$NomeComputador = $NomeComputador.ToUpperInvariant()
$EmpresasPath = Join-Path $Raiz '20-Configuracoes\Empresas\empresas.json'

if (-not (Test-Path $EmpresasPath)) {
    throw "Arquivo nao encontrado: $EmpresasPath"
}

$Config = Get-Content -Path $EmpresasPath -Raw | ConvertFrom-Json
$EmpresaEncontrada = $null
$PrefixoEncontrado = $null

foreach ($Empresa in @($Config.empresas)) {
    foreach ($Prefixo in @($Empresa.prefixos)) {
        $PrefixoNormalizado = ([string]$Prefixo).ToUpperInvariant()

        if ($NomeComputador -like "$PrefixoNormalizado*") {
            $EmpresaEncontrada = $Empresa
            $PrefixoEncontrado = $PrefixoNormalizado
            break
        }
    }

    if ($null -ne $EmpresaEncontrada) {
        break
    }
}

if ($null -eq $EmpresaEncontrada) {
    throw "Nenhuma empresa corresponde ao computador: $NomeComputador"
}

$SophosId = @(
    $EmpresaEncontrada.aplicativos |
        Where-Object { [string]$_ -like 'sophos-*' }
) | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace([string]$SophosId)) {
    throw "Nenhum Sophos configurado para a empresa $($EmpresaEncontrada.nome)."
}

$Variante = ([string]$SophosId -split '-', 2)[1]
$LinkPath = Join-Path $Raiz "30-Links\sophos\$Variante.txt"
$ManifestPath = Join-Path $Raiz "20-Configuracoes\Aplicativos\$SophosId.json"

if (-not (Test-Path $LinkPath)) {
    throw "Arquivo de link ausente: $LinkPath"
}

if (-not (Test-Path $ManifestPath)) {
    throw "Manifesto ausente: $ManifestPath"
}

$Url = (Get-Content -Path $LinkPath -Raw).Trim()
$Manifesto = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "DIAGNOSTICO DO SOPHOS" -ForegroundColor Cyan
Write-Host "Computador : $NomeComputador"
Write-Host "Empresa    : $($EmpresaEncontrada.nome)"
Write-Host "Prefixo    : $PrefixoEncontrado"
Write-Host "Aplicativo : $SophosId"
Write-Host "Link       : $LinkPath"
Write-Host "URL valida : $([Uri]::IsWellFormedUriString($Url, [UriKind]::Absolute))"
Write-Host "Argumentos : $($Manifesto.silentArgs)"
Write-Host "Timeout    : $($Manifesto.installTimeoutSeconds) segundos"
Write-Host "Deteccao   : $((@($Manifesto.detectionPaths) + @($Manifesto.detectionServices) + @($Manifesto.detectionRegistryDisplayNames)) -join ' | ')"
Write-Host ""

if (-not [Uri]::IsWellFormedUriString($Url, [UriKind]::Absolute)) {
    throw "URL invalida para $SophosId."
}

if ([string]$Manifesto.silentArgs -ne '--quiet') {
    throw "Argumento silencioso incorreto para $SophosId."
}

Write-Host "CONFIGURACAO DO SOPHOS VALIDADA." -ForegroundColor Green
