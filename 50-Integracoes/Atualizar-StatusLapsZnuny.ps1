[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$ComputerName,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-IntegrationLog {
    param([string]$Message)
    $line = '{0} [ZNUNY] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($LogPath) { $line | Out-File -FilePath $LogPath -Append -Encoding utf8 }
}

function Write-InstallerLog {
    param($Context, [string]$Message, [string]$Level = 'Info')
    Write-IntegrationLog "[$Level] $Message"
}

. (Join-Path $PSScriptRoot 'Znuny\Znuny.Api.ps1')
$integrationContext = [pscustomobject]@{RepositoryRoot=(Split-Path $PSScriptRoot -Parent)}

try {
    $config = Get-ZnunyConfig -Context $integrationContext -ConfigPath $ConfigPath
    if ($null -eq $config) { throw 'Configuracao do Znuny indisponivel.' }
    $fieldValue = [string](Get-ZnunyProperty $config 'lapsFieldValue')
    if ([string]::IsNullOrWhiteSpace($fieldValue)) { $fieldValue = 'Gerenciado via LAPS' }
    $registered = Send-ZnunyAssetFields -Context $integrationContext -Config $config -ComputerName $ComputerName -Fields @{SenhaUsuarioImagem=$fieldValue}
    if (-not $registered) { throw 'Registro no Znuny nao confirmado.' }
    exit 0
} catch {
    Write-IntegrationLog "ERRO: $($_.Exception.Message)"
    exit 1
}
