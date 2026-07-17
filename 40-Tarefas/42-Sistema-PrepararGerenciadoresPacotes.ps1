param($Context)

function Add-ProcessPathEntry {
    param([string]$Entry)

    if ([string]::IsNullOrWhiteSpace($Entry)) { return }
    $parts = @($env:Path -split ';' | Where-Object { $_ })
    if ($parts -notcontains $Entry) { $env:Path = (($parts + $Entry) -join ';') }
}

function Add-PersistentUserPathEntry {
    param(
        [string]$Entry,
        [string]$Sid = ''
    )

    if ([string]::IsNullOrWhiteSpace($Entry)) { return }

    if (-not [string]::IsNullOrWhiteSpace($Sid)) {
        $environmentPath = "Registry::HKEY_USERS\$Sid\Environment"
        if (-not (Test-Path $environmentPath)) {
            New-Item -Path $environmentPath -Force | Out-Null
        }

        $current = [string](Get-ItemPropertyValue -Path $environmentPath -Name 'Path' -ErrorAction SilentlyContinue)
        $parts = @($current -split ';' | Where-Object { $_ })
        if ($parts -notcontains $Entry) {
            $newValue = (($parts + $Entry) -join ';')
            New-ItemProperty -Path $environmentPath -Name 'Path' -Value $newValue -PropertyType ExpandString -Force | Out-Null
        }
        return
    }

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($current -split ';' | Where-Object { $_ })
    if ($parts -notcontains $Entry) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $Entry) -join ';'), 'User')
    }
}

$windowsAppsTargets = @()
if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $windowsAppsTargets += [pscustomobject]@{
        Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
        Sid = ''
    }
}

try {
    $interactive = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($interactive.UserName) {
        $account = New-Object System.Security.Principal.NTAccount($interactive.UserName)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
        $profile = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.SID -eq $sid } |
            Select-Object -First 1

        if ($profile.LocalPath) {
            $windowsAppsTargets += [pscustomobject]@{
                Path = (Join-Path $profile.LocalPath 'AppData\Local\Microsoft\WindowsApps')
                Sid = $sid
            }
        }
    }
}
catch {
    Write-InstallerLog -Context $Context -Message "Nao foi possivel localizar o perfil interativo para persistir WindowsApps no PATH: $($_.Exception.Message)" -Level Warning
}

foreach ($target in @($windowsAppsTargets | Sort-Object Path, Sid -Unique)) {
    if (Test-Path $target.Path) {
        Add-ProcessPathEntry -Entry $target.Path
        Add-PersistentUserPathEntry -Entry $target.Path -Sid $target.Sid
        Write-InstallerLog -Context $Context -Message "WindowsApps garantido no PATH: $($target.Path)"
    }
}

$winget = Get-WingetExecutable
if ($winget) {
    try {
        Write-InstallerLog -Context $Context -Message "WinGet localizado em: $winget"
        $exitCode = Invoke-WithTimeout `
            -Context $Context `
            -FilePath $winget `
            -ArgumentList 'upgrade Microsoft.AppInstaller --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' `
            -TimeoutSeconds 1800 `
            -Name 'Atualizacao do Microsoft App Installer'

        if ($exitCode -notin @(0, -1978335189, -1978335212)) {
            Write-InstallerLog -Context $Context -Message "Atualizacao do App Installer retornou codigo $exitCode. O instalador continuara." -Level Warning
        }
        else {
            Write-InstallerLog -Context $Context -Message 'Verificacao/atualizacao do Microsoft App Installer concluida.' -Level Success
        }
    }
    catch {
        Write-InstallerLog -Context $Context -Message "Nao foi possivel atualizar o App Installer: $($_.Exception.Message)" -Level Warning
    }
}
else {
    Write-InstallerLog -Context $Context -Message 'WinGet ainda nao esta disponivel. Os aplicativos usarao instalador direto.' -Level Warning
}

$choco = Install-ChocolateyCli `
    -Context $Context

if (
    -not [string]::IsNullOrWhiteSpace(
        [string]$choco
    )
) {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            'Chocolatey disponivel para uso como metodo alternativo: ' +
            [string]$choco
        ) `
        -Level Success
}
else {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            'Chocolatey nao pode ser preparado nesta rodada. O ' +
            'instalador continuara com os demais metodos e tentara ' +
            'prepara-lo novamente quando um aplicativo precisar.'
        ) `
        -Level Warning
}

Write-InstallerLog `
    -Context $Context `
    -Message (
        'Gerenciadores preparados. Cada aplicativo podera utilizar ' +
        'instalador direto, WinGet e Chocolatey conforme o manifesto.'
    ) `
    -Level Success
