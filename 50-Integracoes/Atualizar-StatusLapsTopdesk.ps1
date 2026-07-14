[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$ComputerName,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-IntegrationLog {
    param([string]$Message)
    $line = '{0} [TOPDESK] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($LogPath) { $line | Out-File -FilePath $LogPath -Append -Encoding utf8 }
}

try {
    $config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($required in @('baseUrl','username','password')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.$required)) {
            throw "Campo obrigatorio ausente no arquivo de configuracao: $required"
        }
    }

    $baseUrl = ([string]$config.baseUrl).TrimEnd('/')
    $pair = '{0}:{1}' -f [string]$config.username, [string]$config.password
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    $headers = @{ Authorization = "Basic $basic"; Accept = 'application/json'; 'Content-Type' = 'application/json' }

    $encodedName = [Uri]::EscapeDataString($ComputerName)
    $searchUrl = "$baseUrl/tas/api/assetmgmt/assets?nameFragment=$encodedName"
    Write-IntegrationLog "Localizando ativo $ComputerName."
    $result = Invoke-RestMethod -Uri $searchUrl -Headers $headers -Method Get

    $assets = @($result.dataSet)
    $asset = $assets | Where-Object { $_.name -eq $ComputerName } | Select-Object -First 1
    if (-not $asset) { $asset = $assets | Select-Object -First 1 }
    if (-not $asset.id) { throw "Ativo nao encontrado no TOPdesk: $ComputerName" }

    $fieldName = if ($config.imagePasswordFieldName) { [string]$config.imagePasswordFieldName } elseif ($config.lapsFieldName) { [string]$config.lapsFieldName } else { 'senha-usuario-imagem' }
    $fieldValue = if ($config.lapsFieldValue) { [string]$config.lapsFieldValue } else { 'Gerenciado via LAPS' }
    $body = @{ $fieldName = $fieldValue } | ConvertTo-Json -Depth 3
    $assetUrl = "$baseUrl/tas/api/assetmgmt/assets/$($asset.id)"

    Invoke-RestMethod -Uri $assetUrl -Headers $headers -Method Post -Body $body | Out-Null
    Write-IntegrationLog "Ativo atualizado: $fieldName = $fieldValue."
    exit 0
} catch {
    Write-IntegrationLog "ERRO: $($_.Exception.Message)"
    exit 1
}
