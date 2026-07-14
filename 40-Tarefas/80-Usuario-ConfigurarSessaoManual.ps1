param($Context)

if ($Context.Mode -notin @('Manual', 'IntuneScheduled')) {
    return
}

function Expand-UserRegistryPath {
    param(
        [string]$Value,
        [string]$ProfilePath,
        [string]$Sid
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $expanded = [string]$Value
    $expanded = $expanded.Replace('%USERPROFILE%', $ProfilePath)

    try {
        $environmentPath = "Registry::HKEY_USERS\$Sid\Environment"
        $environment = Get-ItemProperty `
            -Path $environmentPath `
            -ErrorAction SilentlyContinue

        if ($null -ne $environment) {
            foreach ($name in @(
                'OneDrive',
                'OneDriveCommercial',
                'OneDriveConsumer',
                'HOMEDRIVE',
                'HOMEPATH'
            )) {
                $property = $environment.PSObject.Properties[$name]

                if ($null -ne $property -and $null -ne $property.Value) {
                    $expanded = $expanded.Replace(
                        "%$name%",
                        [string]$property.Value
                    )
                }
            }
        }
    }
    catch {}

    return [Environment]::ExpandEnvironmentVariables($expanded)
}

function Get-InteractiveUserTarget {
    param([int]$TimeoutSeconds = 120)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
        $userName = $null
        $sid = $null
        $profilePath = $null
        $desktopPath = $null

        if (-not $isSystem) {
            try {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $userName = $identity.Name
                $sid = $identity.User.Value
                $profilePath = $env:USERPROFILE
                $desktopPath = [Environment]::GetFolderPath('Desktop')
            }
            catch {}
        }
        else {
            try {
                $computerSystem = Get-CimInstance `
                    -ClassName Win32_ComputerSystem `
                    -ErrorAction Stop

                $userName = [string]$computerSystem.UserName

                if (-not [string]::IsNullOrWhiteSpace($userName)) {
                    $account = New-Object `
                        System.Security.Principal.NTAccount($userName)

                    $securityIdentifier = $account.Translate(
                        [System.Security.Principal.SecurityIdentifier]
                    )

                    $sid = $securityIdentifier.Value

                    $profile = Get-CimInstance `
                        -ClassName Win32_UserProfile `
                        -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.SID -eq $sid -and
                            -not $_.Special
                        } |
                        Select-Object -First 1

                    if ($null -ne $profile) {
                        $profilePath = [string]$profile.LocalPath
                    }
                }
            }
            catch {}
        }

        if (
            -not [string]::IsNullOrWhiteSpace($sid) -and
            -not [string]::IsNullOrWhiteSpace($profilePath)
        ) {
            try {
                $userShellFolders = (
                    "Registry::HKEY_USERS\$sid\" +
                    "Software\Microsoft\Windows\CurrentVersion\" +
                    "Explorer\User Shell Folders"
                )

                $desktopRaw = Get-ItemPropertyValue `
                    -Path $userShellFolders `
                    -Name 'Desktop' `
                    -ErrorAction SilentlyContinue

                if (-not [string]::IsNullOrWhiteSpace([string]$desktopRaw)) {
                    $desktopPath = Expand-UserRegistryPath `
                        -Value ([string]$desktopRaw) `
                        -ProfilePath $profilePath `
                        -Sid $sid
                }
            }
            catch {}

            $desktopCandidates = @(
                $desktopPath,
                (Join-Path $profilePath 'Desktop')
            )

            try {
                $oneDriveFolders = @(
                    Get-ChildItem `
                        -Path $profilePath `
                        -Directory `
                        -Filter 'OneDrive*' `
                        -ErrorAction SilentlyContinue
                )

                foreach ($oneDriveFolder in $oneDriveFolders) {
                    $desktopCandidates += (
                        Join-Path $oneDriveFolder.FullName 'Desktop'
                    )
                }
            }
            catch {}

            $desktopPath = $desktopCandidates |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                } |
                Select-Object -First 1

            if (-not [string]::IsNullOrWhiteSpace($desktopPath)) {
                New-Item `
                    -Path $desktopPath `
                    -ItemType Directory `
                    -Force |
                    Out-Null

                return [pscustomobject]@{
                    UserName = $userName
                    Sid = $sid
                    ProfilePath = $profilePath
                    DesktopPath = $desktopPath
                }
            }
        }

        Start-Sleep -Seconds 5
    }
    while ((Get-Date) -lt $deadline)

    throw (
        "Nao foi possivel localizar o usuario interativo e a Area de " +
        "Trabalho dentro de $TimeoutSeconds segundos."
    )
}

function Test-PortableExecutable {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    $file = Get-Item -Path $Path -ErrorAction Stop

    if ($file.Length -lt 500KB) {
        return $false
    }

    $stream = [System.IO.File]::OpenRead($Path)

    try {
        $first = $stream.ReadByte()
        $second = $stream.ReadByte()
    }
    finally {
        $stream.Dispose()
    }

    return ($first -eq 0x4D -and $second -eq 0x5A)
}

function Install-TeamViewerOnDesktop {
    param(
        $Context,
        $UserTarget
    )

    $embedded = Join-Path $Context.RepositoryRoot '80-Recursos\Sessao\TeamViewer.exe'
    $temporaryPath = Join-Path $Context.DownloadDirectory 'TeamViewerQS.exe'
    $source = $null

    if (Test-PortableExecutable -Path $embedded) {
        $source = $embedded
        Write-InstallerLog -Context $Context -Message "Usando TeamViewer offline incluido no pacote: $embedded"
    }
    else {
        $url = Get-AppDownloadUrl -Context $Context -Name 'teamviewer'
        Save-RemoteFile -Context $Context -Uri $url -Destination $temporaryPath -TimeoutSeconds 900
        if (-not (Test-PortableExecutable -Path $temporaryPath)) { throw "Download do TeamViewer invalido: $temporaryPath" }
        $source = $temporaryPath
        Write-InstallerLog -Context $Context -Message 'TeamViewer offline indisponivel; QuickSupport baixado da internet.' -Level Warning
    }

    $destination = Join-Path $UserTarget.DesktopPath 'TeamViewer.exe'
    Copy-Item -Path $source -Destination $destination -Force -ErrorAction Stop
    try { Unblock-File -Path $destination -ErrorAction SilentlyContinue } catch {}
    if (-not (Test-PortableExecutable -Path $destination)) { throw "TeamViewer nao passou na verificacao: $destination" }
    Write-InstallerLog -Context $Context -Message "TeamViewer criado na Area de Trabalho de '$($UserTarget.UserName)': $destination" -Level Success
}

function New-ShutdownShortcut {
    param(
        [string]$ShortcutPath,
        [string]$DestinationVbs,
        [string]$ResourceDirectory
    )

    $shortcutDirectory = Split-Path `
        -Path $ShortcutPath `
        -Parent

    New-Item `
        -Path $shortcutDirectory `
        -ItemType Directory `
        -Force |
        Out-Null

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)

    $shortcut.TargetPath = (
        Join-Path $env:SystemRoot 'System32\wscript.exe'
    )

    $shortcut.Arguments = "`"$DestinationVbs`""
    $shortcut.WorkingDirectory = $ResourceDirectory
    $shortcut.Description = 'Desligar o computador com confirmacao'
    $shortcut.IconLocation = (
        (Join-Path $env:SystemRoot 'System32\shell32.dll') +
        ',27'
    )

    $shortcut.Save()

    if (-not (Test-Path $ShortcutPath)) {
        throw "O atalho de desligamento nao foi criado: $ShortcutPath"
    }

    $shortcutCheck = $shell.CreateShortcut($ShortcutPath)

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$shortcutCheck.TargetPath
        )
    ) {
        throw (
            "O atalho de desligamento foi criado sem destino: " +
            "$ShortcutPath"
        )
    }
}

function Install-CustomShutdownShortcut {
    param(
        $Context,
        $UserTarget
    )

    if ($null -eq $UserTarget) {
        throw (
            'Nao foi possivel criar o atalho Desligar sem localizar ' +
            'a Area de Trabalho do usuario.'
        )
    }

    $sourceVbs = Join-Path `
        $Context.RepositoryRoot `
        '80-Recursos\Sessao\Desligar.vbs'

    if (-not (Test-Path $sourceVbs)) {
        throw "Recurso do desligamento nao encontrado: $sourceVbs"
    }

    $resourceDirectory = Join-Path `
        $env:ProgramData `
        'ImagemTI\Recursos'

    New-Item `
        -Path $resourceDirectory `
        -ItemType Directory `
        -Force |
        Out-Null

    $destinationVbs = Join-Path `
        $resourceDirectory `
        'Desligar.vbs'

    Copy-Item `
        -Path $sourceVbs `
        -Destination $destinationVbs `
        -Force `
        -ErrorAction Stop

    $startMenuDirectory = Join-Path `
        $env:ProgramData `
        'Microsoft\Windows\Start Menu\Programs'

    $startMenuShortcut = Join-Path `
        $startMenuDirectory `
        'Desligar.lnk'

    $desktopShortcut = Join-Path `
        $UserTarget.DesktopPath `
        'Desligar.lnk'

    New-ShutdownShortcut `
        -ShortcutPath $startMenuShortcut `
        -DestinationVbs $destinationVbs `
        -ResourceDirectory $resourceDirectory

    New-ShutdownShortcut `
        -ShortcutPath $desktopShortcut `
        -DestinationVbs $destinationVbs `
        -ResourceDirectory $resourceDirectory

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "Atalho personalizado de desligamento criado no Menu " +
            "Iniciar: $startMenuShortcut"
        ) `
        -Level Success

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "Atalho personalizado de desligamento criado na Area de " +
            "Trabalho de '$($UserTarget.UserName)': $desktopShortcut"
        ) `
        -Level Success
}

$errors = @()

try {
    $userTarget = Get-InteractiveUserTarget -TimeoutSeconds 120

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "Usuario interativo localizado para configuracoes da sessao: " +
            "$($userTarget.UserName). Perfil: " +
            "$($userTarget.ProfilePath). Desktop: " +
            "$($userTarget.DesktopPath)"
        )
}
catch {
    $errors += $_.Exception.Message
    $userTarget = $null

    Write-InstallerLog `
        -Context $Context `
        -Message "Falha ao localizar usuario interativo: $($_.Exception.Message)" `
        -Level Error
}

if ($null -ne $userTarget) {
    try {
        Install-TeamViewerOnDesktop `
            -Context $Context `
            -UserTarget $userTarget
    }
    catch {
        $errors += "TeamViewer: $($_.Exception.Message)"

        Write-InstallerLog `
            -Context $Context `
            -Message "Falha ao criar TeamViewer na Area de Trabalho: $($_.Exception.Message)" `
            -Level Error
    }
}

if ($null -ne $userTarget) {
    try {
        Install-CustomShutdownShortcut `
            -Context $Context `
            -UserTarget $userTarget
    }
    catch {
        $errors += "Desligar: $($_.Exception.Message)"

        Write-InstallerLog `
            -Context $Context `
            -Message (
                "Falha ao criar atalho de desligamento na Area de " +
                "Trabalho: $($_.Exception.Message)"
            ) `
            -Level Error
    }
}
else {
    $errors += (
        'Desligar: usuario interativo nao localizado para criar o ' +
        'atalho na Area de Trabalho.'
    )
}

if ($errors.Count -gt 0) {
    throw (
        "Configuracao da sessao terminou com erro: " +
        ($errors -join ' | ')
    )
}

Write-InstallerLog `
    -Context $Context `
    -Message (
        "Configuracoes da sessao concluidas: TeamViewer na Area de " +
        "Trabalho, e Desligar no Menu Iniciar e na Area de " +
        "Trabalho."
    ) `
    -Level Success
