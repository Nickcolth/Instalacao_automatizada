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
