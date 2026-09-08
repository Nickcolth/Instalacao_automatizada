param($Context, $Manifest, [string]$Name)

$metadataUrl = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json'
$targetVersion = '8.0.30'

Write-InstallerLog -Context $Context -Message "Consultando metadata oficial do .NET para localizar o Desktop Runtime $targetVersion x64."

$metadata = Invoke-RestMethod -Uri $metadataUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
$release = @($metadata.releases | Where-Object { [string]$_."release-version" -eq $targetVersion } | Select-Object -First 1)

if (-not $release) {
    throw ".NET Desktop Runtime $targetVersion nao encontrado na metadata oficial da Microsoft."
}

$file = @($release.windowsdesktop.files | Where-Object { [string]$_.rid -eq 'win-x64' -and [string]$_.url -like '*.exe' } | Select-Object -First 1)

if (-not $file -or [string]::IsNullOrWhiteSpace([string]$file.url)) {
    throw "Instalador x64 do .NET Desktop Runtime $targetVersion nao encontrado na metadata oficial."
}

return [string]$file.url
