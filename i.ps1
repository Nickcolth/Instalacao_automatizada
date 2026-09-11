$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {}

$Repositorio = 'Nickcolth/Instalacao_automatizada'
$Branch = 'main'
$Url = "https://raw.githubusercontent.com/$Repositorio/$Branch/Instalar-Manual-Web.ps1"
$Temp = Join-Path $env:TEMP 'Instalar-Manual-Web.ps1'

Write-Host '[INFO] Baixando instalador manual...'

Invoke-WebRequest `
    -Uri $Url `
    -OutFile $Temp `
    -UseBasicParsing `
    -ErrorAction Stop

# O bootstrap antigo ainda possui uma trava antecipada para o usuario Imagem.
# A validacao correta agora acontece no executor, depois que empresas.json ja
# esta disponivel: Imagem so e liberado se o equipamento tiver prefixo valido.
try {
    $bootstrap = Get-Content -Path $Temp -Raw -Encoding UTF8
    $bootstrap = $bootstrap -replace '(?m)^\s*Bloquear-SeUsuarioImagem\s*$', '# Validacao do usuario Imagem sera feita no executor principal.'
    Set-Content -Path $Temp -Value $bootstrap -Encoding UTF8 -Force
}
catch {
    throw "Falha ao preparar a validacao do usuario Imagem: $($_.Exception.Message)"
}

try {
    Unblock-File -Path $Temp -ErrorAction SilentlyContinue
}
catch {}

Write-Host '[INFO] Iniciando instalador manual...'

& powershell.exe `
    -NoLogo `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $Temp `
    -Repositorio $Repositorio `
    -Branch $Branch

exit $LASTEXITCODE
