[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory)]
    [string]$AppName,

    [string]$PackageVersion = 'sem-versao',

    [int]$Attempt = 1,

    [int]$MaxInstallAttempts = 3,

    [Parameter(Mandatory)]
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$resultDirectory = Split-Path `
    -Path $ResultPath `
    -Parent

if (
    -not [string]::IsNullOrWhiteSpace($resultDirectory)
) {
    New-Item `
        -Path $resultDirectory `
        -ItemType Directory `
        -Force |
        Out-Null
}

$result = [ordered]@{
    Success = $false
    AppName = $AppName
    Identity = ''
    LogPath = ''
    Message = ''
}

$exitCode = 1

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $result.Identity = [string]$identity.Name

    if (-not $identity.IsSystem) {
        throw (
            'A tarefa temporaria nao iniciou como SYSTEM. Identidade: ' +
            $identity.Name
        )
    }

    $modulePath = Join-Path `
        $RepositoryRoot `
        '10-Nucleo\Instalador.Nucleo.psm1'

    if (-not (Test-Path $modulePath)) {
        throw "Nucleo do instalador nao encontrado: $modulePath"
    }

    Import-Module `
        $modulePath `
        -Force `
        -ErrorAction Stop

    $context = New-InstallerContext `
        -Mode 'ManualSystem' `
        -RepositoryRoot $RepositoryRoot `
        -MaxInstallAttempts $MaxInstallAttempts `
        -PackageVersion $PackageVersion

    $result.LogPath = [string]$context.LogPath

    Write-InstallerLog `
        -Context $context `
        -Message (
            "Execucao SYSTEM iniciada para '$AppName'. Identidade: " +
            "$($identity.Name). Tentativa: $Attempt."
        ) `
        -Level Success

    $installed = Install-AppFromManifest `
        -Context $context `
        -Name $AppName `
        -Attempt $Attempt

    if (-not $installed) {
        throw (
            "Install-AppFromManifest retornou falha para '$AppName'."
        )
    }

    if (
        -not (
            Test-AppInstalledByName `
                -Context $context `
                -Name $AppName
        )
    ) {
        throw (
            "A instalacao de '$AppName' terminou, mas a deteccao " +
            'final nao confirmou o aplicativo.'
        )
    }

    $result.Success = $true
    $result.Message = (
        "Aplicativo '$AppName' instalado e confirmado como SYSTEM."
    )
    $exitCode = 0
}
catch {
    $result.Message = $_.Exception.Message
}
finally {
    $result |
        ConvertTo-Json -Depth 5 |
        Set-Content `
            -Path $ResultPath `
            -Encoding UTF8 `
            -Force
}

exit $exitCode
