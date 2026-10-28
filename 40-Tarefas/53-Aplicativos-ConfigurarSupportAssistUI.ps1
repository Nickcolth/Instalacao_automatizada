param($Context)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# SupportAssist UI is a per-user MSIX package. The Dell agent is machine-wide.
$packagePath = 'C:\Program Files\Dell\SupportAssistAgent\bin\Appx\SupportAssist_x64.msix'
$sourceScript = Join-Path $Context.RepositoryRoot '40-Tarefas\54-Aplicativos-RegistrarSupportAssistUI-Usuario.ps1'
$targetDirectory = Join-Path $env:ProgramData 'ImagemTI\SupportAssist'
$targetScript = Join-Path $targetDirectory 'RegistrarSupportAssistUI.ps1'
$activeSetupPath = 'SOFTWARE\Microsoft\Active Setup\Installed Components\{0F64DDF1-BB12-4DAB-8A79-B7D3D30AB928}'

if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    throw "SupportAssist: pacote da interface nao encontrado: $packagePath"
}
if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
    throw "SupportAssist: script de registro nao encontrado: $sourceScript"
}

New-Item -Path $targetDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force -ErrorAction Stop

# Active Setup runs once for each user at Explorer startup, including future profiles.
$stubPath = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $targetScript + '"'
$baseKey = $null
$key = $null
try {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    $key = $baseKey.CreateSubKey($activeSetupPath, $true)
    if ($null -eq $key) { throw 'Nao foi possivel criar Active Setup do SupportAssist.' }
    $key.SetValue('Version', '1,0,0,0', [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('StubPath', $stubPath, [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('IsInstalled', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    $key.SetValue('(Default)', 'ImagemTI - Dell SupportAssist UI', [Microsoft.Win32.RegistryValueKind]::String)
}
finally {
    if ($null -ne $key) { $key.Dispose() }
    if ($null -ne $baseKey) { $baseKey.Dispose() }
}

Write-InstallerLog -Context $Context -Message 'SupportAssist: Active Setup registrado para usuarios futuros.' -Level Success

# Register now only if the installer is running as the actual user.
# Under SYSTEM or elevated with a different account, the user login will register it.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsSystem) {
    Write-InstallerLog -Context $Context -Message 'SupportAssist: execucao SYSTEM; registro da interface sera feito no login do usuario.' -Level Warning
    return
}

try {
    & $targetScript
    Write-InstallerLog -Context $Context -Message "SupportAssist: interface validada para $($identity.Name)." -Level Success
}
catch {
    Write-InstallerLog -Context $Context -Message "SupportAssist: registro imediato falhou: $($_.Exception.Message). Active Setup tentara no proximo login." -Level Warning
    throw
}
