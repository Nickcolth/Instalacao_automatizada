# Executado no contexto do usuario (diretamente ou pelo Active Setup).
# O agente Dell e o pacote MSIX ja devem existir no computador.
$ErrorActionPreference = 'Stop'

$packagePath = 'C:\Program Files\Dell\SupportAssistAgent\bin\Appx\SupportAssist_x64.msix'
$appName = 'DellInc.DellSupportAssistforPCs'
$appId = 'DellInc.DellSupportAssistforPCs_htrsf667h5kn2!App'
$logDirectory = Join-Path $env:LOCALAPPDATA 'ImagemTI'
$logPath = Join-Path $logDirectory 'SupportAssistUI.log'

function Write-SupportAssistUILog {
    param([string]$Message)

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Output $line

    try {
        New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Nao foi possivel gravar log do SupportAssist: $($_.Exception.Message)"
    }
}

try {
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw 'O registro MSIX deve ser executado como usuario, nao como SYSTEM.'
    }

    $installed = Get-AppxPackage -Name $appName -ErrorAction Stop |
        Select-Object -First 1
    $startApp = Get-StartApps -ErrorAction Stop |
        Where-Object { $_.AppID -eq $appId } |
        Select-Object -First 1

    if ($installed -and $startApp) {
        Write-SupportAssistUILog 'Interface do SupportAssist ja registrada para este usuario.'
        return
    }

    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "Pacote MSIX nao encontrado: $packagePath"
    }

    Write-SupportAssistUILog "Registrando interface MSIX para $env:USERNAME."
    Add-AppxPackage -Path $packagePath -ErrorAction Stop

    $ready = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $installed = Get-AppxPackage -Name $appName -ErrorAction Stop |
            Select-Object -First 1
        $startApp = Get-StartApps -ErrorAction Stop |
            Where-Object { $_.AppID -eq $appId } |
            Select-Object -First 1

        if ($installed -and $startApp) {
            $ready = $true
            break
        }

        Start-Sleep -Seconds 2
    }

    if (-not $ready) {
        throw 'Pacote MSIX instalado, mas o aplicativo nao foi confirmado no Menu Iniciar.'
    }

    Write-SupportAssistUILog 'Interface registrada e confirmada no Menu Iniciar.'
}
catch {
    Write-SupportAssistUILog "FALHA: $($_.Exception.Message)"
    throw
}
