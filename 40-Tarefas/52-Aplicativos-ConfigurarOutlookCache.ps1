param($Context)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# SyncWindowSetting = 0: Outlook classico sincroniza todos os e-mails.
# HKCU do SYSTEM nao e o registro do colaborador; usar HKEY_USERS.
$relativePath = 'Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode'

$profiles = @(
    Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special -and $_.Loaded -and $_.SID }
)

$configured = 0
foreach ($profile in $profiles) {
    $sid = [string]$profile.SID
    $path = "Registry::HKEY_USERS\$sid\$relativePath"
    try {
        New-Item -Path $path -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $path -Name 'SyncWindowSetting' `
            -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        $value = Get-ItemPropertyValue -Path $path `
            -Name 'SyncWindowSetting' -ErrorAction Stop
        if ([int]$value -ne 0) {
            throw 'SyncWindowSetting nao ficou com valor 0.'
        }
        $configured++
        Write-InstallerLog -Context $Context `
            -Message "Outlook configurado para baixar todos os e-mails. Perfil: $sid" `
            -Level Success
    }
    catch {
        Write-InstallerLog -Context $Context `
            -Message "Falha ao configurar Outlook para $sid`: $($_.Exception.Message)" `
            -Level Warning
    }
}

if ($configured -eq 0) {
    throw 'Nenhum perfil de usuario carregado recebeu a configuracao do Outlook.'
}

Write-InstallerLog -Context $Context `
    -Message "Outlook: sincronizacao completa aplicada em $configured perfil(is)." `
    -Level Success
