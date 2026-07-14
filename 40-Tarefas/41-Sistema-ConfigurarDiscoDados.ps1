param($Context)
$disk = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq 'D:' -and $_.DriveType -eq 3 }
if ($disk) {
    $profilePath = 'D:\Profile'
    New-Item -Path $profilePath -ItemType Directory -Force | Out-Null
    try { Set-Volume -DriveLetter D -NewFileSystemLabel 'Data' -ErrorAction Stop } catch {}
    Write-InstallerLog -Context $Context -Message 'Disco D: configurado e pasta D:\Profile criada.'
} else {
    Write-InstallerLog -Context $Context -Message 'Disco D: fixo nao encontrado.' -Level Warning
}
