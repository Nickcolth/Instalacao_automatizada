param($Context)

$service = Get-Service -Name 'WerSvc' -ErrorAction SilentlyContinue
if ($null -eq $service) {
    Write-InstallerLog -Context $Context -Message 'Servico WerSvc nao encontrado. Nenhuma alteracao necessaria.' -Level Warning
    return
}

try { Stop-Service -Name 'WerSvc' -Force -ErrorAction SilentlyContinue } catch {}
Set-Service -Name 'WerSvc' -StartupType Disabled -ErrorAction Stop

$check = Get-CimInstance Win32_Service -Filter "Name='WerSvc'" -ErrorAction Stop
if ([string]$check.StartMode -ne 'Disabled') {
    throw "WerSvc nao ficou desativado. StartMode atual: $($check.StartMode)"
}

Write-InstallerLog -Context $Context -Message 'Servico WerSvc parado e configurado como Disabled.' -Level Success
