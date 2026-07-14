[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = Split-Path `
    -Path $MyInvocation.MyCommand.Path `
    -Parent

$manifestPath = Join-Path `
    $root `
    '20-Configuracoes\Aplicativos\java-runtime.json'

$linkPath = Join-Path `
    $root `
    '30-Links\java-runtime\padrao.txt'

$manifest = Get-Content `
    -Path $manifestPath `
    -Raw `
    -Encoding ASCII |
    ConvertFrom-Json

$link = (
    Get-Content `
        -Path $linkPath `
        -Raw `
        -Encoding ASCII
).Trim()

Write-Host ''
Write-Host 'DIAGNOSTICO DO JAVA' -ForegroundColor Cyan
Write-Host ''

Write-Host (
    'Link configurado: ' +
    $link
)

Write-Host (
    'Primeiro metodo: ' +
    [string]$manifest.packageManagerOrder[0]
)

Write-Host (
    'Parametros: ' +
    [string]$manifest.silentArgs
)

Write-Host (
    'Tamanho minimo: ' +
    [string]$manifest.minimumInstallerBytes +
    ' bytes'
)

$found = $false

foreach ($pattern in @(
    'C:\Program Files\Java\jre*\bin\java.exe',
    (
        'C:\Program Files\Common Files\Oracle\Java\' +
        'javapath\java.exe'
    ),
    'C:\Program Files (x86)\Java\jre*\bin\java.exe'
)) {
    foreach (
        $javaPath in @(
            Get-Item `
                -Path $pattern `
                -ErrorAction SilentlyContinue
        )
    ) {
        Write-Host (
            'Java detectado: ' +
            $javaPath.FullName
        ) -ForegroundColor Green

        $found = $true
    }
}

if (-not $found) {
    Write-Host (
        'Java ainda nao foi localizado nos caminhos configurados.'
    ) -ForegroundColor Yellow
}

Write-Host ''
