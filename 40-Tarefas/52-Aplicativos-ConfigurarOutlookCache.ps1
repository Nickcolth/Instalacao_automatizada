param($Context)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# SyncWindowSetting = 0: Outlook classico sincroniza todos os e-mails.
# HKCU do SYSTEM nao e o registro do colaborador; usar HKEY_USERS.
$relativePath = 'Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode'

# Active Setup: configura o Outlook no primeiro login de cada usuario.
# Isso tambem cobre perfis criados depois da preparacao do computador.
$activeSetupKeyPath = 'SOFTWARE\Microsoft\Active Setup\Installed Components\{E1F1D1A0-5A39-49D8-9F1D-BA9A98E7BFD0}'
$stubPath = 'reg.exe add "HKCU\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode" /v SyncWindowSetting /t REG_DWORD /d 0 /f'
$baseKey = $null
$activeSetupKey = $null

try {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    $activeSetupKey = $baseKey.CreateSubKey($activeSetupKeyPath, $true)
    if ($null -eq $activeSetupKey) {
        throw 'Nao foi possivel criar a chave do Active Setup.'
    }
    $activeSetupKey.SetValue('Version', '1,0,0,0', [Microsoft.Win32.RegistryValueKind]::String)
    $activeSetupKey.SetValue('StubPath', $stubPath, [Microsoft.Win32.RegistryValueKind]::String)
    $activeSetupKey.SetValue('IsInstalled', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
}
finally {
    if ($null -ne $activeSetupKey) { $activeSetupKey.Dispose() }
    if ($null -ne $baseKey) { $baseKey.Dispose() }
}

Write-InstallerLog -Context $Context `
    -Message 'Outlook: Active Setup registrado para configurar perfis futuros no primeiro login.' `
    -Level Success

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
    Write-InstallerLog -Context $Context `
        -Message 'Nenhum perfil carregado. Active Setup aplicara a configuracao no proximo login.' `
        -Level Warning
}

Write-InstallerLog -Context $Context `
    -Message "Outlook: sincronizacao completa aplicada em $configured perfil(is)." `
    -Level Success
