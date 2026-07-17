param($Context)

function Get-OfficeComponentState {
    $components = @(
        [pscustomobject]@{ Name='Microsoft 365'; Id='microsoft-office'; Paths=@('C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE','C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE') },
        [pscustomobject]@{ Name='Microsoft Project'; Id='microsoft-project'; Paths=@('C:\Program Files\Microsoft Office\root\Office16\WINPROJ.EXE','C:\Program Files (x86)\Microsoft Office\root\Office16\WINPROJ.EXE') },
        [pscustomobject]@{ Name='Microsoft Visio'; Id='microsoft-visio'; Paths=@('C:\Program Files\Microsoft Office\root\Office16\VISIO.EXE','C:\Program Files (x86)\Microsoft Office\root\Office16\VISIO.EXE') }
    )

    $results = @()
    foreach ($component in $components) {
        $evidence = $null
        foreach ($path in $component.Paths) {
            if (Test-Path $path) { $evidence = $path; break }
        }
        $results += [pscustomobject]@{ Name=$component.Name; Id=$component.Id; Installed=($null -ne $evidence); Evidence=$evidence }
    }
    return $results
}

function Test-ExecutableFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    if ((Get-Item $Path).Length -lt 4096) { return $false }
    $stream=[IO.File]::OpenRead($Path)
    try { $a=$stream.ReadByte(); $b=$stream.ReadByte() } finally { $stream.Dispose() }
    return ($a -eq 0x4D -and $b -eq 0x5A)
}

function Get-OdtCandidates {
    $urls = @(
        'https://officecdn.microsoft.com/pr/wsus/setup.exe',
        (
            'https://download.microsoft.com/download/' +
            '6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/' +
            'officedeploymenttool_20131-20090.exe'
        )
    )

    $catalogPages = @(
        (
            'https://www.microsoft.com/en-us/download/' +
            'details.aspx?id=49117'
        ),
        (
            'https://www.microsoft.com/pt-br/download/' +
            'details.aspx?id=49117'
        )
    )

    foreach ($page in $catalogPages) {
        try {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'Consultando o catalogo oficial do Office ' +
                    "Deployment Tool: $page"
                )

            $response = Invoke-WebRequest `
                -Uri $page `
                -UseBasicParsing `
                -TimeoutSec 60 `
                -ErrorAction Stop

            $matches = [regex]::Matches(
                [string]$response.Content,
                'https://download\.microsoft\.com/[^"''<>\s]+\.exe',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            foreach ($match in @($matches)) {
                $urls += [Net.WebUtility]::HtmlDecode(
                    [string]$match.Value
                )
            }
        }
        catch {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'A consulta opcional ao catalogo do ODT falhou em ' +
                    "${page}: $($_.Exception.Message). As origens " +
                    'diretas da Microsoft continuam disponiveis.'
                )
        }
    }

    return @(
        $urls |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            } |
            Select-Object -Unique
    )
}

function Get-OfficeSetup {
    param([string]$OfficeFolder)

    $setup = Join-Path $OfficeFolder 'setup.exe'
    foreach ($url in @(Get-OdtCandidates)) {
        try {
            $downloaded = Join-Path $OfficeFolder 'OfficeDeploymentTool.exe'
            Save-RemoteFile -Context $Context -Uri $url -Destination $downloaded -TimeoutSeconds 1800
            if (-not (Test-ExecutableFile -Path $downloaded)) { throw 'Arquivo baixado nao e um executavel valido.' }

            if ($url -like '*officecdn.microsoft.com*') {
                Copy-Item -Path $downloaded -Destination $setup -Force
            }
            else {
                $arguments = "/quiet /extract:`"$OfficeFolder`""
                $code = Invoke-WithTimeout -Context $Context -FilePath $downloaded -ArgumentList $arguments -TimeoutSeconds 600 -Name 'Extracao do Office Deployment Tool'
                if ($code -notin @(0,3010)) { throw "Extrator do ODT retornou $code." }
            }

            if (Test-ExecutableFile -Path $setup) {
                Write-InstallerLog -Context $Context -Message "Office Deployment Tool preparado a partir de: $url" -Level Success
                return $setup
            }
        }
        catch {
            Write-InstallerLog -Context $Context -Message "Falha ao preparar ODT por ${url}: $($_.Exception.Message)" -Level Warning
        }
    }
    throw 'Nenhuma origem forneceu um setup.exe valido do Office Deployment Tool.'
}

function Write-RecentClickToRunLogs {
    $folders = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) | Where-Object { $_ -and (Test-Path $_) }
    $logs = @()
    foreach ($folder in $folders) {
        $logs += Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'ClickToRun|Office|ODT' -and $_.Extension -eq '.log' }
    }
    foreach ($log in @($logs | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
        Write-InstallerLog -Context $Context -Message "Log recente do Office: $($log.FullName) | $($log.LastWriteTime)"
    }
}

$completed = $false
$lastError = $null

for (
    $attempt = 1;
    $attempt -le $Context.MaxInstallAttempts;
    $attempt++
) {
    $beforeAttempt = @(
        Get-OfficeComponentState
    )

    $missingBefore = @(
        $beforeAttempt |
            Where-Object {
                -not $_.Installed
            }
    )

    foreach ($component in $beforeAttempt) {
        if ($component.Installed) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "[$attempt/$($Context.MaxInstallAttempts)] " +
                    "Pre-verificacao: $($component.Name) ja instalado. " +
                    "$($component.Evidence)"
                ) `
                -Level Success
        }
        else {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "[$attempt/$($Context.MaxInstallAttempts)] " +
                    "Pre-verificacao: $($component.Name) ausente."
                ) `
                -Level Warning
        }
    }

    if ($missingBefore.Count -eq 0) {
        foreach ($component in $beforeAttempt) {
            Add-InstallerResult `
                -Context $Context `
                -Type 'app' `
                -Name $component.Id `
                -Status 'AlreadyInstalled' `
                -Attempt $attempt `
                -Message $component.Evidence
        }

        $completed = $true
        break
    }

    try {
        $officeFolder = Join-Path `
            $Context.DownloadDirectory `
            "OfficeInstall-$attempt"

        if (Test-Path $officeFolder) {
            Remove-Item `
                -Path $officeFolder `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        New-Item `
            -Path $officeFolder `
            -ItemType Directory `
            -Force |
            Out-Null

        $configSource = Join-Path `
            $Context.RepositoryRoot `
            '20-Configuracoes\office-configuration.xml'

        $config = Join-Path `
            $officeFolder `
            'config.xml'

        Copy-Item `
            -Path $configSource `
            -Destination $config `
            -Force

        $setup = Get-OfficeSetup `
            -OfficeFolder $officeFolder

        Write-InstallerLog `
            -Context $Context `
            -Message (
                "[$attempt/$($Context.MaxInstallAttempts)] " +
                "Baixando Microsoft 365, Project e Visio."
            )

        $downloadCode = Invoke-WithTimeout `
            -Context $Context `
            -FilePath $setup `
            -ArgumentList "/download `"$config`"" `
            -TimeoutSeconds 7200 `
            -HeartbeatSeconds 60 `
            -MonitorPath $officeFolder `
            -Name (
                "Download do Office - tentativa $attempt"
            )

        if ($downloadCode -notin @(0, 3010)) {
            throw "ODT /download retornou $downloadCode."
        }

        $beforeConfigure = @(
            Get-OfficeComponentState |
                Where-Object {
                    -not $_.Installed
                }
        )

        if ($beforeConfigure.Count -eq 0) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'Office detectado antes do /configure. ' +
                    'Nenhuma reinstalacao sera executada.'
                ) `
                -Level Success

            $completed = $true
            break
        }

        Write-InstallerLog `
            -Context $Context `
            -Message (
                "[$attempt/$($Context.MaxInstallAttempts)] " +
                "Instalando Microsoft 365, Project e Visio."
            )

        $configureCode = Invoke-WithTimeout `
            -Context $Context `
            -FilePath $setup `
            -ArgumentList "/configure `"$config`"" `
            -TimeoutSeconds 7200 `
            -HeartbeatSeconds 60 `
            -MonitorPath $officeFolder `
            -Name (
                "Instalacao do Office - tentativa $attempt"
            )

        if ($configureCode -notin @(0, 3010)) {
            throw "ODT /configure retornou $configureCode."
        }

        $detectionDeadline = (Get-Date).AddMinutes(5)
        $afterAttempt = @(
            Get-OfficeComponentState
        )

        while (
            @(
                $afterAttempt |
                    Where-Object {
                        -not $_.Installed
                    }
            ).Count -gt 0 -and
            (Get-Date) -lt $detectionDeadline
        ) {
            Start-Sleep -Seconds 10
            $afterAttempt = @(
                Get-OfficeComponentState
            )
        }

        $missingAfter = @(
            $afterAttempt |
                Where-Object {
                    -not $_.Installed
                }
        )

        foreach ($component in $afterAttempt) {
            if ($component.Installed) {
                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        "[$attempt/$($Context.MaxInstallAttempts)] " +
                        "$($component.Name) instalado e verificado. " +
                        "$($component.Evidence)"
                    ) `
                    -Level Success

                Add-InstallerResult `
                    -Context $Context `
                    -Type 'app' `
                    -Name $component.Id `
                    -Status 'Success' `
                    -Attempt $attempt `
                    -ExitCode $configureCode `
                    -Message $component.Evidence
            }
        }

        if ($missingAfter.Count -eq 0) {
            $completed = $true
            break
        }

        throw (
            "Componentes nao detectados: " +
            "$((@($missingAfter.Name)) -join ', ')"
        )
    }
    catch {
        $lastError = $_.Exception.Message

        Write-InstallerLog `
            -Context $Context `
            -Message (
                "[$attempt/$($Context.MaxInstallAttempts)] " +
                "Falha no Office: $lastError"
            ) `
            -Level Error

        Add-InstallerResult `
            -Context $Context `
            -Type 'app' `
            -Name 'microsoft-office-suite' `
            -Status 'Failed' `
            -Attempt $attempt `
            -Message $lastError

        if ($attempt -lt $Context.MaxInstallAttempts) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'Microsoft 365, Project e Visio serao ' +
                    'verificados e tentados novamente.'
                ) `
                -Level Warning

            Start-Sleep -Seconds 15
        }
    }
    finally {
        Write-RecentClickToRunLogs
    }
}

$finalOfficeState = @(
    Get-OfficeComponentState
)

$finalOfficeMissing = @(
    $finalOfficeState |
        Where-Object {
            -not $_.Installed
        }
)

if (
    -not $completed -or
    $finalOfficeMissing.Count -gt 0
) {
    throw (
        "Microsoft 365, Project ou Visio continuam ausentes depois de " +
        "$($Context.MaxInstallAttempts) tentativas. Ausentes: " +
        "$((@($finalOfficeMissing.Name)) -join ', '). " +
        "Ultimo erro: $lastError"
    )
}

Write-InstallerLog `
    -Context $Context `
    -Message (
        'Verificacao final do Office concluida: Microsoft 365, ' +
        'Project e Visio instalados.'
    ) `
    -Level Success
