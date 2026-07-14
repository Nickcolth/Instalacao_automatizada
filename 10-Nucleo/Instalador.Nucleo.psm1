Set-StrictMode -Version 2.0

function Initialize-ContextState {
    param($Context)

    if ($null -eq $Context) {
        throw 'Contexto do instalador nao foi informado.'
    }

    if ($Context.PSObject.Properties.Name -notcontains 'InstallerResults') {
        $Context | Add-Member -MemberType NoteProperty -Name InstallerResults -Value @()
    }
    elseif ($null -eq $Context.InstallerResults) {
        $Context.InstallerResults = @()
    }

    if ($Context.PSObject.Properties.Name -notcontains 'RequiredAplicativos') {
        $Context | Add-Member -MemberType NoteProperty -Name RequiredAplicativos -Value @()
    }
    elseif ($null -eq $Context.RequiredAplicativos) {
        $Context.RequiredAplicativos = @()
    }

    if ($Context.PSObject.Properties.Name -notcontains 'SuccessfulApps') {
        $Context | Add-Member -MemberType NoteProperty -Name SuccessfulApps -Value @()
    }
    elseif ($null -eq $Context.SuccessfulApps) {
        $Context.SuccessfulApps = @()
    }
}

function New-InstallerContext {
    param(
        [string]$Mode,
        [string]$RepositoryRoot,
        [int]$MaxInstallAttempts = 3,
        [string]$PackageVersion = 'sem-versao'
    )
    $base = Join-Path $env:ProgramData 'ImagemTI\Instalador'
    $logDir = Join-Path $base 'Logs'
    $downloadDir = Join-Path $base 'Downloads'
    $flagDir = Join-Path $base 'Flags'
    $reportDir = Join-Path $base 'Relatorios'
    New-Item -Path $base, $logDir, $downloadDir, $flagDir, $reportDir -ItemType Directory -Force | Out-Null

    $runId = Get-Date -Format 'yyyyMMdd_HHmmss'

    [pscustomobject]@{
        Mode = $Mode
        IsIntune = ($Mode -like 'Intune*')
        IsScheduled = ($Mode -eq 'IntuneScheduled')
        RepositoryRoot = $RepositoryRoot
        BaseDirectory = $base
        LogPath = Join-Path $logDir ("installer_{0}_{1}.log" -f $Mode.ToLower(), $runId)
        DownloadDirectory = $downloadDir
        FlagDirectory = $flagDir
        ReportDirectory = $reportDir
        SummaryPath = Join-Path $reportDir ("summary_{0}_{1}.json" -f $Mode.ToLower(), $runId)
        FlagPath = Join-Path $flagDir ("installed_{0}.flag" -f $Mode.ToLower())
        FailedFlagPath = Join-Path $flagDir ("failed_{0}.flag" -f $Mode.ToLower())
        MaxInstallAttempts = $MaxInstallAttempts
        PackageVersion = $PackageVersion
        InstallerResults = @()

        RequiredAplicativos = @()

        SuccessfulApps = @()

    }
}

function Write-InstallerLog {
    param(
        $Context,
        [string]$Message,
        [ValidateSet('Info','Warning','Error','Success')]
        [string]$Level='Info'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message
    $line | Out-File -FilePath $Context.LogPath -Append -Encoding utf8
    Write-Host $line
}

function Add-InstallerResult {
    param(
        $Context,
        [string]$Type,
        [string]$Name,
        [string]$Status,
        [string]$Message,
        [int]$Attempt = 0,
        [int]$ExitCode = -999999
    )

    Initialize-ContextState -Context $Context

    $item = [pscustomobject]@{
        date = (Get-Date -Format o)
        type = $Type
        name = $Name
        status = $Status
        attempt = $Attempt
        exitCode = $(if ($ExitCode -eq -999999) { $null } else { $ExitCode })
        message = $Message
    }

    $Context.InstallerResults = @($Context.InstallerResults) + @($item)

    if (
        $Type -ieq 'app' -and
        @('Success','Installed','AlreadyInstalled') -contains $Status -and
        -not [string]::IsNullOrWhiteSpace($Name) -and
        @($Context.SuccessfulApps) -notcontains $Name
    ) {
        $Context.SuccessfulApps = @($Context.SuccessfulApps) + @([string]$Name)
    }
}



function Get-InstallerResults {
    param($Context)

    Initialize-ContextState -Context $Context

    foreach ($item in @($Context.InstallerResults)) {
        $item
    }
}



function Register-RequiredApp {
    param(
        $Context,
        [string]$Name
    )

    Initialize-ContextState -Context $Context

    if (
        -not [string]::IsNullOrWhiteSpace($Name) -and
        @($Context.RequiredAplicativos) -notcontains $Name
    ) {
        $Context.RequiredAplicativos = @($Context.RequiredAplicativos) + @([string]$Name)
    }
}



function Get-RequiredAplicativos {
    param($Context)

    Initialize-ContextState -Context $Context

    foreach ($name in @($Context.RequiredAplicativos)) {
        [string]$name
    }
}




function Get-AppInstallAttemptCount {
    param(
        $Context,
        [string]$Name
    )

    Initialize-ContextState -Context $Context

    $attemptNumbers = @(
        $Context.InstallerResults |
            Where-Object {
                $_.type -eq 'app' -and
                $_.name -eq $Name -and
                [int]$_.attempt -gt 0
            } |
            ForEach-Object {
                [int]$_.attempt
            }
    )

    if ($attemptNumbers.Count -eq 0) {
        return 0
    }

    return [int](
        $attemptNumbers |
            Measure-Object -Maximum
    ).Maximum
}

function Write-InstallerSummary {
    param(
        $Context,
        [string]$FinalStatus,
        $MissingAplicativos = @(),
        $FailedTasks = @()
    )
    $missingList = @(
        $MissingAplicativos |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    $failedList = @(
        $FailedTasks |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    $requiredList = @(
        Get-RequiredAplicativos -Context $Context |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    $resultList = @()
    foreach ($resultItem in (Get-InstallerResults -Context $Context)) {
        $resultList += ,$resultItem
    }

    $summary = [pscustomobject]@{
        nomeComputador = $env:COMPUTERNAME
        modo = $Context.Mode
        statusFinal = $FinalStatus
        dataGeracao = (Get-Date -Format o)
        caminhoLog = $Context.LogPath
        aplicativosPendentes = $missingList
        tarefasComErro = $failedList
        aplicativosObrigatorios = $requiredList
        resultados = $resultList
    }

    $summary |
        ConvertTo-Json -Depth 8 |
        Out-File -FilePath $Context.SummaryPath -Encoding UTF8 -Force

    Write-InstallerLog -Context $Context -Message "Resumo JSON gerado em: $($Context.SummaryPath)"
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'O instalador precisa ser executado como administrador ou pelo Intune no contexto SYSTEM.'
    }
}


function Get-UserNameOnly {
    param([string]$IdentityName)

    if ([string]::IsNullOrWhiteSpace($IdentityName)) { return '' }

    $value = [string]$IdentityName
    if ($value -like '*\*') {
        return ($value -split '\\')[-1]
    }

    return $value
}

function Test-UsuarioBloqueadoPorNome {
    param(
        [string]$IdentityName,
        [string[]]$BlockedUserNames = @('Imagem')
    )

    $userOnly = Get-UserNameOnly -IdentityName $IdentityName
    if ([string]::IsNullOrWhiteSpace($userOnly)) { return $false }

    foreach ($blocked in $BlockedUserNames) {
        if ($userOnly -ieq $blocked) { return $true }
    }

    return $false
}

function Get-UsuariosInterativosAtuais {
    $usuarios = @()

    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computerSystem.UserName) {
            $usuarios += [pscustomobject]@{
                UserName = [string]$computerSystem.UserName
                SessionId = $null
                State = 'Active'
                Source = 'Win32_ComputerSystem'
            }
        }
    } catch {}

    try {
        $queryOutput = & query.exe user 2>$null
        foreach ($line in @($queryOutput)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match 'USERNAME\s+SESSIONNAME') { continue }

            $clean = ([string]$line).Trim()
            $clean = $clean -replace '^>', ''
            $parts = $clean -split '\s+'
            if ($parts.Count -lt 2) { continue }

            $userName = [string]$parts[0]
            $sessionId = $null
            foreach ($part in $parts) {
                if ($part -match '^\d+$') {
                    $sessionId = [int]$part
                    break
                }
            }

            $state = if ($parts -contains 'Active') { 'Active' } elseif ($parts -contains 'Disc') { 'Disc' } else { '' }

            $usuarios += [pscustomobject]@{
                UserName = $userName
                SessionId = $sessionId
                State = $state
                Source = 'query user'
            }
        }
    } catch {}

    try {
        $explorerProcesses = Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue
        foreach ($proc in @($explorerProcesses)) {
            if ($proc.UserName) {
                $usuarios += [pscustomobject]@{
                    UserName = [string]$proc.UserName
                    SessionId = $null
                    State = 'Active'
                    Source = 'explorer.exe'
                }
            }
        }
    } catch {}

    return @(
        $usuarios |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.UserName) } |
            Sort-Object UserName, SessionId -Unique
    )
}

function Show-AvisoUsuarioBloqueado {
    param(
        [string]$Message = 'Execucao bloqueada. O instalador nao pode ser executado pelo usuario Imagem. Faca logoff e entre com a conta do colaborador, depois execute novamente.',
        [string]$Title = 'Instalador bloqueado - usuario nao permitido'
    )

    $isSystem = $false
    try { $isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch {}

    if ($isSystem) {
        $shown = $false
        try {
            $sessions = @(Get-UsuariosInterativosAtuais | Where-Object { $null -ne $_.SessionId } | Sort-Object SessionId -Unique)
            foreach ($session in $sessions) {
                try {
                    & msg.exe $session.SessionId /time:120 $Message 2>$null | Out-Null
                    $shown = $true
                } catch {}
            }
        } catch {}

        if (-not $shown) {
            try { & msg.exe * /time:120 $Message 2>$null | Out-Null } catch {}
        }

        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Warning') | Out-Null
        return
    } catch {}

    try {
        $shell = New-Object -ComObject WScript.Shell
        $null = $shell.Popup($Message, 120, $Title, 48)
        return
    } catch {}

    Write-Host $Message
}

function Test-ExecucaoUsuarioBloqueado {
    param([string[]]$BlockedUserNames = @('Imagem'))

    $identity = $null
    try { $identity = [Security.Principal.WindowsIdentity]::GetCurrent() } catch {}

    if ($null -ne $identity -and -not $identity.IsSystem) {
        if (Test-UsuarioBloqueadoPorNome -IdentityName $identity.Name -BlockedUserNames $BlockedUserNames) { return $true }
        if (Test-UsuarioBloqueadoPorNome -IdentityName $env:USERNAME -BlockedUserNames $BlockedUserNames) { return $true }
        return $false
    }

    foreach ($usuario in @(Get-UsuariosInterativosAtuais)) {
        if (Test-UsuarioBloqueadoPorNome -IdentityName $usuario.UserName -BlockedUserNames $BlockedUserNames) {
            return $true
        }
    }

    return $false
}

function Assert-UsuarioPermitido {
    param(
        $Context,
        [string[]]$BlockedUserNames = @('Imagem')
    )

    if (-not (Test-ExecucaoUsuarioBloqueado -BlockedUserNames $BlockedUserNames)) { return }

    $message = 'Execucao bloqueada: o instalador nao pode ser executado pelo usuario Imagem. Faca logoff e entre com a conta do colaborador, depois execute novamente.'

    try { Show-AvisoUsuarioBloqueado -Message $message } catch {}

    if ($null -ne $Context) {
        try {
            Write-InstallerLog -Context $Context -Message $message -Level Error
            New-Item -Path $Context.FlagDirectory -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $Context.FlagDirectory 'bloqueado_usuario_imagem.flag') -Value (Get-Date -Format o) -Encoding ASCII -Force
        } catch {}
    }

    throw $message
}

function Wait-Internet {
    param($Context, [int]$TimeoutSeconds=180)

    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            Invoke-WebRequest -Uri 'https://www.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 8 | Out-Null
            return
        } catch {
            Start-Sleep -Seconds 5
        }
    } while ((Get-Date) -lt $end)

    throw "Conexao com a internet nao ficou disponivel em $TimeoutSeconds segundos."
}

function Get-AppManifest {
    param($Context, [string]$Name)

    $path = Join-Path $Context.RepositoryRoot "20-Configuracoes\Aplicativos\$Name.json"
    if (-not (Test-Path $path)) { throw "Manifesto do aplicativo nao encontrado: $path" }
    Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) { return $DefaultValue }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }

    return $property.Value
}

function Get-ManifestBool {
    param(
        $Manifest,
        [string]$Name,
        [bool]$DefaultValue = $false
    )

    $value = Get-ObjectPropertyValue -Object $Manifest -Name $Name -DefaultValue $DefaultValue
    if ($null -eq $value) { return $DefaultValue }

    try { return [bool]$value } catch { return $DefaultValue }
}

function Get-ManifestArray {
    param(
        $Manifest,
        [string]$Name
    )

    $value = Get-ObjectPropertyValue -Object $Manifest -Name $Name -DefaultValue $null
    if ($null -eq $value) { return }

    foreach ($item in $value) {
        $item
    }
}

function Get-ManifestStringArray {
    param(
        $Manifest,
        [string]$Name
    )

    return @(
        Get-ManifestArray -Manifest $Manifest -Name $Name |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}



function Get-LinkPartsFromAppName {
    param([string]$Name)

    $programa = $Name
    $variante = ''

    if ($Name -like '*-*') {
        $parts = $Name -split '-', 2
        $programa = $parts[0]
        $variante = $parts[1]
    }

    return [pscustomobject]@{
        Programa = $programa
        Variante = $variante
    }
}

function Read-UrlFromLinkFile {
    param([string]$Path)

    $url = (Get-Content -Path $Path -Raw -Encoding UTF8).Trim()

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "O arquivo de link esta vazio: $Path"
    }

    if ($url -like 'SUBSTITUIR_*') {
        throw "O link ainda nao foi configurado: $Path"
    }

    if (-not [Uri]::IsWellFormedUriString($url, [UriKind]::Absolute)) {
        throw "URL invalida em $Path"
    }

    return $url
}

function Get-AppDownloadUrl {
    param($Context, [string]$Name)

    $parts = Get-LinkPartsFromAppName -Name $Name

    $linkRoots = @(
        (Join-Path $Context.RepositoryRoot '60-Segredos\Links'),
        (Join-Path $Context.RepositoryRoot '30-Links')
    )

    foreach ($linksRoot in $linkRoots) {
        if (-not (Test-Path $linksRoot)) { continue }

        $candidateDirectories = @()
        $candidateDirectories += (Join-Path $linksRoot $Name)

        if ($parts.Programa -ne $Name) {
            $candidateDirectories += (Join-Path $linksRoot $parts.Programa)
        }

        foreach ($dir in @($candidateDirectories | Select-Object -Unique)) {
            if (-not (Test-Path $dir)) { continue }

            $files = @(
                Get-ChildItem -Path $dir -Filter '*.txt' -File -ErrorAction SilentlyContinue |
                    Sort-Object Name
            )

            if ($files.Count -eq 0) {
                throw "A pasta de links esta vazia: $dir"
            }

            if ($files.Count -eq 1) {
                Write-InstallerLog -Context $Context -Message "Link selecionado para '$Name': $($files[0].FullName)"
                return (Read-UrlFromLinkFile -Path $files[0].FullName)
            }

            if (-not [string]::IsNullOrWhiteSpace($parts.Variante)) {
                $match = $files |
                    Where-Object {
                        [IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $parts.Variante
                    } |
                    Select-Object -First 1

                if ($match) {
                    Write-InstallerLog -Context $Context -Message "Link selecionado para '$Name' pela variante '$($parts.Variante)': $($match.FullName)"
                    return (Read-UrlFromLinkFile -Path $match.FullName)
                }
            }

            $padrao = $files |
                Where-Object {
                    [IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq 'padrao'
                } |
                Select-Object -First 1

            if ($padrao) {
                Write-InstallerLog -Context $Context -Message "Link padrao selecionado para '$Name': $($padrao.FullName)"
                return (Read-UrlFromLinkFile -Path $padrao.FullName)
            }

            $names = ($files | ForEach-Object { $_.Name }) -join ', '
            throw "Mais de um link encontrado em $dir, mas nao foi possivel escolher a variante de '$Name'. Arquivos: $names"
        }

    }

    throw "Link nao encontrado para '$Name'. Verifique 60-Segredos\Links ou 30-Links."
}

function Get-ExpandedDetectionPaths {
    param($Manifest)

    $paths = @()
    foreach ($path in @(Get-ManifestStringArray -Manifest $Manifest -Name 'detectionPaths')) {
        $paths += [Environment]::ExpandEnvironmentVariables([string]$path)
    }

    return @($paths)
}

function Get-InstalledProgramDisplayNames {
    $displayNames = @()

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($registryPath in $registryPaths) {
        try {
            foreach ($entry in @(Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue)) {
                $property = $entry.PSObject.Properties['DisplayName']
                if ($null -eq $property) { continue }

                $displayName = [string]$property.Value
                if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                    $displayNames += $displayName
                }
            }
        } catch {}
    }

    return @($displayNames | Sort-Object -Unique)
}

function Get-AppDetectionResult {
    param(
        $Manifest
    )

    $criteriaCount = 0
    $paths = @(Get-ExpandedDetectionPaths -Manifest $Manifest)

    if ($paths.Count -gt 0) {
        $criteriaCount += $paths.Count

        foreach ($path in $paths) {
            if (Test-Path $path) {
                return [pscustomobject]@{
                    Installed = $true
                    CanDetect = $true
                    Method = 'Path'
                    Evidence = $path
                    Message = "Detectado pelo caminho: $path"
                }
            }
        }
    }

    $displayNamePatterns = @(
        Get-ManifestStringArray -Manifest $Manifest -Name 'detectionRegistryDisplayNames'
    )

    if ($displayNamePatterns.Count -gt 0) {
        $criteriaCount += $displayNamePatterns.Count
        $installedDisplayNames = @(Get-InstalledProgramDisplayNames)

        foreach ($pattern in $displayNamePatterns) {
            $match = $installedDisplayNames |
                Where-Object { $_ -like $pattern } |
                Select-Object -First 1

            if ($match) {
                return [pscustomobject]@{
                    Installed = $true
                    CanDetect = $true
                    Method = 'Registry'
                    Evidence = [string]$match
                    Message = "Detectado no registro: $match"
                }
            }
        }
    }

    $servicePatterns = @(
        Get-ManifestStringArray -Manifest $Manifest -Name 'detectionServices'
    )

    if ($servicePatterns.Count -gt 0) {
        $criteriaCount += $servicePatterns.Count

        foreach ($servicePattern in $servicePatterns) {
            $service = Get-Service `
                -Name $servicePattern `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if (-not $service) {
                $service = Get-Service `
                    -DisplayName $servicePattern `
                    -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }

            if ($service) {
                return [pscustomobject]@{
                    Installed = $true
                    CanDetect = $true
                    Method = 'Service'
                    Evidence = [string]$service.Name
                    Message = (
                        "Detectado pelo servico: $($service.Name) / " +
                        "$($service.DisplayName)"
                    )
                }
            }
        }
    }

    if ($criteriaCount -eq 0) {
        return [pscustomobject]@{
            Installed = $false
            CanDetect = $false
            Method = ''
            Evidence = ''
            Message = 'Manifesto sem criterio de deteccao confiavel.'
        }
    }

    return [pscustomobject]@{
        Installed = $false
        CanDetect = $true
        Method = ''
        Evidence = ''
        Message = 'Aplicativo nao localizado pelos criterios configurados.'
    }
}

function Wait-AppDetection {
    param(
        $Manifest,
        [int]$TimeoutSeconds = 90,
        [int]$IntervalSeconds = 5
    )

    $endTime = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastResult = Get-AppDetectionResult -Manifest $Manifest

    if (-not $lastResult.CanDetect -or $lastResult.Installed) {
        return $lastResult
    }

    do {
        Start-Sleep -Seconds $IntervalSeconds
        $lastResult = Get-AppDetectionResult -Manifest $Manifest

        if ($lastResult.Installed) {
            return $lastResult
        }
    } while ((Get-Date) -lt $endTime)

    return $lastResult
}



function Get-InstalledByManifest {
    param($Manifest)

    $detection = Get-AppDetectionResult -Manifest $Manifest
    return [bool]$detection.Installed
}

function Test-AppSucceededInCurrentRun {
    param(
        $Context,
        [string]$Name
    )

    Initialize-ContextState -Context $Context

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return (@($Context.SuccessfulApps) -contains $Name)
}

function Test-AppInstalledByName {
    param($Context, [string]$Name)

    try {
        $manifest = Get-AppManifest -Context $Context -Name $Name
        $detection = Get-AppDetectionResult -Manifest $manifest

        if ($detection.Installed) {
            return $true
        }

        $skipPostDetection = Get-ManifestBool `
            -Manifest $manifest `
            -Name 'skipPostDetection' `
            -DefaultValue $false

        if ($skipPostDetection -and (Test-AppSucceededInCurrentRun -Context $Context -Name $Name)) {
            Write-InstallerLog `
                -Context $Context `
                -Message "Aplicativo '$Name' sem deteccao tecnica; considerando o codigo de saida aceito desta execucao." `
                -Level Warning

            return $true
        }

        return $false
    } catch {
        Write-InstallerLog -Context $Context -Message "Falha ao verificar aplicativo '$Name': $($_.Exception.Message)" -Level Error
        return $false
    }
}



function Invoke-WithTimeout {
    param(
        $Context,
        [string]$FilePath,
        [string]$ArgumentList = '',
        [int]$TimeoutSeconds = 1800,
        [string]$Name = 'processo'
    )
    Write-InstallerLog -Context $Context -Message "Iniciando $Name com timeout de $TimeoutSeconds segundos."

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $finished) {
        try { $process.Kill() } catch {}
        throw "$Name travou ou excedeu o timeout de $TimeoutSeconds segundos. Processo encerrado."
    }

    return [int]$process.ExitCode
}

function Save-RemoteFile {
    param(
        $Context,
        [string]$Uri,
        [string]$Destination,
        [int]$TimeoutSeconds = 900
    )

    Wait-Internet -Context $Context | Out-Null
    Remove-Item $Destination -Force -ErrorAction SilentlyContinue

    Write-InstallerLog -Context $Context -Message "Baixando arquivo para $Destination"

    $job = Start-Job -ScriptBlock {
        param($Source, $Target)
        try {
            Start-BitsTransfer -Source $Source -Destination $Target -ErrorAction Stop
        } catch {
            Invoke-WebRequest -Uri $Source -OutFile $Target -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        }
    } -ArgumentList $Uri, $Destination

    $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $finished) {
        Stop-Job -Job $job -Force -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "Download excedeu o timeout de $TimeoutSeconds segundos: $Uri"
    }

    try {
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $Destination)) {
        throw "Download finalizado, mas o arquivo nao foi encontrado: $Destination"
    }
}

function Get-WingetExecutable {
    $candidates = @()

    try {
        $command = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($null -ne $command) { $candidates += [string]$command.Source }
    }
    catch {}

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe')
    }

    $candidates += (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe')

    try {
        $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
        if (Test-Path $windowsApps) {
            $packages = Get-ChildItem -Path $windowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
            foreach ($package in @($packages)) {
                $candidates += (Join-Path $package.FullName 'winget.exe')
            }
        }
    }
    catch {}

    foreach ($candidate in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

function Get-ChocolateyExecutable {
    $candidates = @()

    try {
        $command = Get-Command choco.exe -ErrorAction SilentlyContinue
        if ($null -ne $command) { $candidates += [string]$command.Source }
    }
    catch {}

    if (-not [string]::IsNullOrWhiteSpace($env:ChocolateyInstall)) {
        $candidates += (Join-Path $env:ChocolateyInstall 'bin\choco.exe')
    }

    $candidates += (Join-Path $env:ProgramData 'chocolatey\bin\choco.exe')

    foreach ($candidate in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

function Resolve-AppDownloadUrl {
    param(
        $Context,
        [string]$Name,
        $Manifest
    )

    $resolverRelative = [string](Get-ObjectPropertyValue -Object $Manifest -Name 'downloadResolverScript' -DefaultValue '')

    if (-not [string]::IsNullOrWhiteSpace($resolverRelative)) {
        $resolverPath = Join-Path $Context.RepositoryRoot $resolverRelative
        if (-not (Test-Path $resolverPath)) {
            throw "Resolvedor de URL nao encontrado para '$Name': $resolverPath"
        }

        Write-InstallerLog -Context $Context -Message "Executando resolvedor dinamico de URL para '$Name': $resolverRelative"
        $resolved = & $resolverPath -Context $Context -Manifest $Manifest -Name $Name
        $url = [string](@($resolved | Where-Object { $_ }) | Select-Object -Last 1)

        if ([string]::IsNullOrWhiteSpace($url)) {
            throw "O resolvedor dinamico nao retornou URL para '$Name'."
        }

        if (-not [Uri]::IsWellFormedUriString($url, [UriKind]::Absolute)) {
            throw "O resolvedor dinamico retornou URL invalida para '$Name'."
        }

        return $url
    }

    return (Get-AppDownloadUrl -Context $Context -Name $Name)
}

function Test-InstallerExecutable {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }
    $item = Get-Item -Path $Path -ErrorAction Stop
    if ($item.Length -lt 4096) { return $false }

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

function Test-AppAfterMethod {
    param(
        $Context,
        [string]$Name,
        [string]$DisplayName,
        $Manifest,
        [string]$Method,
        [int]$Attempt,
        [int]$ExitCode
    )

    $skipPostDetection = Get-ManifestBool -Manifest $Manifest -Name 'skipPostDetection' -DefaultValue $false

    if ($skipPostDetection) {
        Write-InstallerLog -Context $Context -Message "${DisplayName}: metodo $Method terminou com codigo aceito; deteccao pos-instalacao desativada." -Level Warning
        Add-InstallerResult -Context $Context -Type 'app' -Name $Name -Status 'Success' -Attempt $Attempt -ExitCode $ExitCode -Message "Instalado por $Method; deteccao pos-instalacao desativada."
        return $true
    }

    $postDetectionTimeout = 120
    try {
        $postDetectionTimeout = [int](Get-ObjectPropertyValue -Object $Manifest -Name 'postDetectionTimeoutSeconds' -DefaultValue 120)
    }
    catch {}

    $detection = Wait-AppDetection -Manifest $Manifest -TimeoutSeconds $postDetectionTimeout -IntervalSeconds 5

    if ($detection.Installed) {
        Write-InstallerLog -Context $Context -Message "${DisplayName}: instalado por $Method e verificado. $($detection.Message)" -Level Success
        Add-InstallerResult -Context $Context -Type 'app' -Name $Name -Status 'Success' -Attempt $Attempt -ExitCode $ExitCode -Message "Metodo: $Method. $($detection.Message)"
        return $true
    }

    Write-InstallerLog -Context $Context -Message "${DisplayName}: o metodo $Method terminou, mas a deteccao falhou. $($detection.Message)" -Level Warning
    return $false
}

function Install-AppFromManifest {
    param(
        $Context,
        [string]$Name,
        [int]$Attempt = 1,
        [switch]$ThrowOnFailure
    )

    Register-RequiredApp -Context $Context -Name $Name

    try {
        $manifest = Get-AppManifest -Context $Context -Name $Name
        $displayName = [string](Get-ObjectPropertyValue -Object $manifest -Name 'displayName' -DefaultValue $Name)
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $Name }

        $initialDetection = Get-AppDetectionResult -Manifest $manifest
        if ($initialDetection.Installed) {
            Write-InstallerLog -Context $Context -Message "[$Attempt/$($Context.MaxInstallAttempts)] $displayName ja esta instalado. $($initialDetection.Message)" -Level Success
            Add-InstallerResult -Context $Context -Type 'app' -Name $Name -Status 'Installed' -Attempt $Attempt -Message $initialDetection.Message
            return $true
        }

        $order = @(Get-ManifestStringArray -Manifest $manifest -Name 'packageManagerOrder')
        if ($order.Count -eq 0) { $order = @('direct') }
        if ($order -notcontains 'direct') { $order += 'direct' }
        $order = @($order | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)

        $installTimeout = 1800
        try { $installTimeout = [int](Get-ObjectPropertyValue -Object $manifest -Name 'installTimeoutSeconds' -DefaultValue 1800) } catch {}

        $successExitCodes = @(Get-ManifestArray -Manifest $manifest -Name 'successExitCodes' | ForEach-Object { [int]$_ })
        if ($successExitCodes.Count -eq 0) { $successExitCodes = @(0, 3010) }

        $errors = @()

        foreach ($method in $order) {
            try {
                $beforeMethodDetection = Get-AppDetectionResult `
                    -Manifest $manifest

                if ($beforeMethodDetection.Installed) {
                    Write-InstallerLog `
                        -Context $Context `
                        -Message (
                            "[$Attempt/$($Context.MaxInstallAttempts)] " +
                            "$displayName foi detectado antes de usar " +
                            "o metodo '$method'. Nenhuma reinstalacao " +
                            "sera executada. " +
                            "$($beforeMethodDetection.Message)"
                        ) `
                        -Level Success

                    Add-InstallerResult `
                        -Context $Context `
                        -Type 'app' `
                        -Name $Name `
                        -Status 'AlreadyInstalled' `
                        -Attempt $Attempt `
                        -Message $beforeMethodDetection.Message

                    return $true
                }

                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        "[$Attempt/$($Context.MaxInstallAttempts)] " +
                        "Pre-verificacao confirmada: $displayName " +
                        "continua ausente. Metodo: $method."
                    )

                if ($method -eq 'chocolatey') {
                    $packageId = [string](Get-ObjectPropertyValue -Object $manifest -Name 'chocolateyPackageId' -DefaultValue '')
                    if ([string]::IsNullOrWhiteSpace($packageId)) { continue }

                    $choco = Get-ChocolateyExecutable
                    if ([string]::IsNullOrWhiteSpace([string]$choco)) {
                        Write-InstallerLog -Context $Context -Message "${displayName}: Chocolatey nao esta disponivel; tentando o proximo metodo." -Level Warning
                        continue
                    }

                    Write-InstallerLog -Context $Context -Message "[$Attempt/$($Context.MaxInstallAttempts)] Instalando $displayName pelo Chocolatey. Pacote: $packageId"
                    $args = "install `"$packageId`" --force --ignore-checksums --no-progress -y"
                    $exitCode = Invoke-WithTimeout -Context $Context -FilePath $choco -ArgumentList $args -TimeoutSeconds $installTimeout -Name "$displayName via Chocolatey"
                    if ($exitCode -notin @(0, 1641, 3010)) { throw "Chocolatey retornou codigo $exitCode." }
                    if (Test-AppAfterMethod -Context $Context -Name $Name -DisplayName $displayName -Manifest $manifest -Method 'Chocolatey' -Attempt $Attempt -ExitCode $exitCode) { return $true }
                    continue
                }

                if ($method -eq 'winget') {
                    $packageId = [string](Get-ObjectPropertyValue -Object $manifest -Name 'wingetPackageId' -DefaultValue '')
                    if ([string]::IsNullOrWhiteSpace($packageId)) { continue }

                    $winget = Get-WingetExecutable
                    if ([string]::IsNullOrWhiteSpace([string]$winget)) {
                        Write-InstallerLog -Context $Context -Message "${displayName}: WinGet nao esta disponivel; tentando o proximo metodo." -Level Warning
                        continue
                    }

                    Write-InstallerLog -Context $Context -Message "[$Attempt/$($Context.MaxInstallAttempts)] Instalando $displayName pelo WinGet. ID: $packageId"
                    $additionalWingetArgs = [string](
                        Get-ObjectPropertyValue `
                            -Object $manifest `
                            -Name 'wingetAdditionalArgs' `
                            -DefaultValue ''
                    )

                    $args = (
                        "install --id `"$packageId`" --exact --silent " +
                        "--accept-package-agreements " +
                        "--accept-source-agreements " +
                        "--disable-interactivity"
                    )

                    if (
                        -not [string]::IsNullOrWhiteSpace(
                            $additionalWingetArgs
                        )
                    ) {
                        $args += " $additionalWingetArgs"
                    }

                    $exitCode = Invoke-WithTimeout -Context $Context -FilePath $winget -ArgumentList $args -TimeoutSeconds $installTimeout -Name "$displayName via WinGet"
                    if ($exitCode -notin @(0, 1641, 3010)) { throw "WinGet retornou codigo $exitCode." }
                    if (Test-AppAfterMethod -Context $Context -Name $Name -DisplayName $displayName -Manifest $manifest -Method 'WinGet' -Attempt $Attempt -ExitCode $exitCode) { return $true }
                    continue
                }

                if ($method -eq 'direct') {
                    $url = Resolve-AppDownloadUrl -Context $Context -Name $Name -Manifest $manifest
                    $fileName = [string](Get-ObjectPropertyValue -Object $manifest -Name 'fileName' -DefaultValue "$Name.exe")
                    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "$Name.exe" }

                    $downloadTimeout = 900
                    try { $downloadTimeout = [int](Get-ObjectPropertyValue -Object $manifest -Name 'downloadTimeoutSeconds' -DefaultValue 900) } catch {}
                    $arguments = [string](Get-ObjectPropertyValue -Object $manifest -Name 'silentArgs' -DefaultValue '')
                    $installer = Join-Path $Context.DownloadDirectory $fileName

                    Write-InstallerLog -Context $Context -Message "[$Attempt/$($Context.MaxInstallAttempts)] Baixando instalador direto de $displayName."
                    Save-RemoteFile -Context $Context -Uri $url -Destination $installer -TimeoutSeconds $downloadTimeout

                    if (
                        $fileName -like '*.exe' -and
                        -not (
                            Test-InstallerExecutable `
                                -Path $installer
                        )
                    ) {
                        throw (
                            "O download de $displayName nao parece ser " +
                            "um executavel Windows valido."
                        )
                    }

                    $minimumInstallerBytes = 0

                    try {
                        $minimumInstallerBytes = [long](
                            Get-ObjectPropertyValue `
                                -Object $manifest `
                                -Name 'minimumInstallerBytes' `
                                -DefaultValue 0
                        )
                    }
                    catch {}

                    if ($minimumInstallerBytes -gt 0) {
                        $installerLength = (
                            Get-Item `
                                -Path $installer `
                                -ErrorAction Stop
                        ).Length

                        if (
                            $installerLength -lt
                            $minimumInstallerBytes
                        ) {
                            throw (
                                "O instalador de $displayName possui " +
                                "$installerLength bytes. O minimo " +
                                "esperado e $minimumInstallerBytes bytes."
                            )
                        }

                        Write-InstallerLog `
                            -Context $Context `
                            -Message (
                                "Tamanho do instalador de $displayName " +
                                "validado: $installerLength bytes."
                            ) `
                            -Level Success
                    }

                    Write-InstallerLog -Context $Context -Message "[$Attempt/$($Context.MaxInstallAttempts)] Instalando $displayName pelo instalador direto."
                    $exitCode = Invoke-WithTimeout -Context $Context -FilePath $installer -ArgumentList $arguments -TimeoutSeconds $installTimeout -Name "$displayName via instalador direto"
                    if ($successExitCodes -notcontains $exitCode) { throw "$displayName retornou codigo $exitCode." }
                    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue

                    if (Test-AppAfterMethod -Context $Context -Name $Name -DisplayName $displayName -Manifest $manifest -Method 'Instalador direto' -Attempt $Attempt -ExitCode $exitCode) { return $true }
                    continue
                }
            }
            catch {
                $methodError = $_.Exception.Message
                $errors += "${method}: $methodError"
                Write-InstallerLog -Context $Context -Message "${displayName}: falha pelo metodo ${method}: $methodError" -Level Warning
            }
        }

        throw "Nenhum metodo instalou $displayName. $($errors -join ' | ')"
    }
    catch {
        $msg = $_.Exception.Message
        Write-InstallerLog -Context $Context -Message "Falha no aplicativo '$Name' na tentativa ${Attempt}: $msg" -Level Error
        Add-InstallerResult -Context $Context -Type 'app' -Name $Name -Status 'Failed' -Attempt $Attempt -Message $msg
        if ($ThrowOnFailure) { throw }
        return $false
    }
}

function Test-AppDetectedByManifest {
    param(
        $Context,
        [string]$Name,
        $Manifest = $null
    )

    try {
        if ($null -eq $Manifest) {
            $Manifest = Get-AppManifest -Context $Context -Name $Name
        }

        $detection = Get-AppDetectionResult -Manifest $Manifest

        return [pscustomobject]@{
            Name = $Name
            Installed = [bool]$detection.Installed
            CanDetect = [bool]$detection.CanDetect
            Message = [string]$detection.Message
        }
    } catch {
        return [pscustomobject]@{
            Name = $Name
            Installed = $false
            CanDetect = $false
            Message = "Falha na deteccao inicial: $($_.Exception.Message)"
        }
    }
}



function Get-EmpresaAppsPorNomeEquipamento {
    param($Context)

    $computerName = $env:COMPUTERNAME.ToUpperInvariant()
    $configPath = Join-Path $Context.RepositoryRoot '20-Configuracoes\Empresas\empresas.json'

    if (Test-Path $configPath) {
        try {
            $config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $baseApps = @()
            if ($config.PSObject.Properties.Name -contains 'aplicativosPadrao') {
                $baseApps = @($config.aplicativosPadrao | ForEach-Object { [string]$_ })
            }

            foreach ($empresa in @($config.empresas)) {
                foreach ($prefixo in @($empresa.prefixos)) {
                    $prefix = ([string]$prefixo).ToUpperInvariant()
                    if ($computerName -like "$prefix*") {
                        $apps = @()
                        $apps += $baseApps
                        $apps += @($empresa.aplicativos | ForEach-Object { [string]$_ })
                        $apps = @($apps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
                        Write-InstallerLog -Context $Context -Message "Empresa identificada pelo nome do equipamento: $($empresa.nome). Prefixo: $prefix. Apps: $($apps -join ', ')"
                        return [pscustomobject]@{
                            Nome = [string]$empresa.nome
                            Prefixo = $prefix
                            Aplicativos = $apps
                            Reconhecida = $true
                        }
                    }
                }
            }

            $appsDefault = @($baseApps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            if ($appsDefault.Count -eq 0) { $appsDefault = @('guardian','journey') }
            Write-InstallerLog -Context $Context -Message "Prefixo nao reconhecido: $computerName. Apps padrao: $($appsDefault -join ', ')" -Level Warning
            return [pscustomobject]@{
                Nome = 'Nao reconhecida'
                Prefixo = ''
                Aplicativos = $appsDefault
                Reconhecida = $false
            }
        } catch {
            Write-InstallerLog -Context $Context -Message "Falha ao ler configuracao de empresas: $($_.Exception.Message). Usando regra interna de emergencia." -Level Warning
        }
    }

    $apps = @('guardian','journey')
    switch -Wildcard ($computerName) {
        'NOTEGESTAO*' { $apps += @('atlas-atmis','sophos-grupo') }
        'NOTEOPT*'    { $apps += @('atlas-geo','sophos-grupo') }
        'NOTEGEO*'    { $apps += @('atlas-geo','sophos-grupo') }
        'NOTESIS*'    { $apps += @('atlas-kaffa','sophos-grupo') }
        'NOTEKAFFA*'  { $apps += @('atlas-kaffa','sophos-grupo') }
        'NOTEVEGA*'   { $apps += @('atlas-vega','sophos-vega') }
        'NOTEVUNOX*'  { $apps += @('atlas-geo','sophos-grupo') }
        default { Write-InstallerLog -Context $Context -Message "Prefixo nao reconhecido: $computerName. Guardian/Journey serao instalados; Atlas/Sophos foram ignorados." -Level Warning }
    }

    return [pscustomobject]@{
        Nome = 'Regra interna'
        Prefixo = ''
        Aplicativos = @($apps | Select-Object -Unique)
        Reconhecida = $true
    }
}

function Get-AppsPlanejadosPorContexto {
    param($Context, $Profile)

    $apps = @()

    foreach ($app in @(Get-ProfileRequiredAplicativos -Profile $Profile)) {
        if (-not [string]::IsNullOrWhiteSpace($app)) { $apps += [string]$app }
    }

    $tasks = @()
    if ($Profile.PSObject.Properties.Name -contains 'tarefas') {
        $tasks = @($Profile.tarefas | ForEach-Object { [string]$_ })
    }
    elseif ($Profile.PSObject.Properties.Name -contains 'tasks') {
        $tasks = @($Profile.tasks | ForEach-Object { [string]$_ })
    }

    foreach ($task in $tasks) {
        switch ($task) {
            '10-Seguranca-InstalarAgentesEmpresa' {
                $empresaApps = Get-EmpresaAppsPorNomeEquipamento -Context $Context
                foreach ($app in @($empresaApps.Aplicativos)) { $apps += [string]$app }
            }
            '50-Aplicativos-InstalarBase' {
                if ($Context.IsIntune) {
                    foreach ($app in @('7zip','google-chrome','java-runtime')) { $apps += $app }
                }
                else {
                    foreach ($app in @('7zip','adobe-reader','google-chrome','firefox','supportassist','java-runtime')) { $apps += $app }
                }
            }
        }
    }

    return @($apps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Invoke-AppInstallSet {
    param(
        $Context,
        [string[]]$AppNames,
        [string]$StageName = 'Aplicativos'
    )

    $apps = @($AppNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    foreach ($app in $apps) { Register-RequiredApp -Context $Context -Name $app }

    if ($apps.Count -eq 0) {
        Write-InstallerLog -Context $Context -Message "${StageName}: nenhum aplicativo selecionado."
        return $true
    }

    Write-InstallerLog -Context $Context -Message "${StageName}: verificando aplicativos ja instalados antes de baixar qualquer instalador."

    $appsToInstall = @()
    foreach ($app in $apps) {
        try {
            $manifest = Get-AppManifest -Context $Context -Name $app
            $displayName = if ($manifest.displayName) { [string]$manifest.displayName } else { $app }
            $detection = Test-AppDetectedByManifest -Context $Context -Name $app -Manifest $manifest

            if ($detection.Installed) {
                Write-InstallerLog -Context $Context -Message "${StageName}: $displayName ja esta instalado. Nao sera reinstalado." -Level Success
                Add-InstallerResult -Context $Context -Type 'app' -Name $app -Status 'AlreadyInstalled' -Message 'Ignorado na etapa porque ja estava instalado.'
            }
            else {
                if (-not $detection.CanDetect) {
                    Write-InstallerLog -Context $Context -Message "${StageName}: $displayName nao possui deteccao inicial confiavel. A instalacao sera executada." -Level Warning
                }
                else {
                    Write-InstallerLog -Context $Context -Message "${StageName}: $displayName nao encontrado. Entrara na fila de instalacao."
                }
                $appsToInstall += $app
            }
        } catch {
            Write-InstallerLog -Context $Context -Message "${StageName}: falha na verificacao inicial de '$app'. Entrara na fila de instalacao. Erro: $($_.Exception.Message)" -Level Warning
            $appsToInstall += $app
        }
    }

    if ($appsToInstall.Count -eq 0) {
        Write-InstallerLog -Context $Context -Message "${StageName}: todos os aplicativos da etapa ja estavam instalados. Nenhum download sera feito." -Level Success
        return $true
    }

    Write-InstallerLog -Context $Context -Message "${StageName}: aplicativos que serao instalados: $($appsToInstall -join ', ')"

    $ok = $true
    foreach ($app in $appsToInstall) {
        $result = Install-AppFromManifest -Context $Context -Name $app -Attempt 1
        if (-not $result) { $ok = $false }
    }

    if (-not $ok) {
        Write-InstallerLog -Context $Context -Message "$StageName terminou com pendencias. O instalador continuara e tentara novamente na verificacao final." -Level Warning
    }

    return $ok
}

function Invoke-InitialAppVerification {
    param(
        $Context,
        [string[]]$AppNames
    )

    $apps = @($AppNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($apps.Count -eq 0) {
        Write-InstallerLog -Context $Context -Message 'Verificacao inicial: nenhum aplicativo planejado para validar.'
        return
    }

    Write-InstallerLog -Context $Context -Message "Verificacao inicial de aplicativos antes de instalar. Apps planejados: $($apps -join ', ')"

    foreach ($app in $apps) {
        try {
            $manifest = Get-AppManifest -Context $Context -Name $app
            $displayName = if ($manifest.displayName) { [string]$manifest.displayName } else { $app }
            $detection = Test-AppDetectedByManifest -Context $Context -Name $app -Manifest $manifest

            if ($detection.Installed) {
                Write-InstallerLog -Context $Context -Message "Verificacao inicial: $displayName ja instalado. $($detection.Message)" -Level Success
                Add-InstallerResult -Context $Context -Type 'app-precheck' -Name $app -Status 'AlreadyInstalled' -Message $detection.Message
            }
            elseif (-not $detection.CanDetect) {
                Write-InstallerLog -Context $Context -Message "Verificacao inicial: $displayName nao tem deteccao confiavel. $($detection.Message)" -Level Warning
                Add-InstallerResult -Context $Context -Type 'app-precheck' -Name $app -Status 'NoDetection' -Message $detection.Message
            }
            else {
                Write-InstallerLog -Context $Context -Message "Verificacao inicial: $displayName nao encontrado. Sera instalado se a tarefa correspondente for executada."
                Add-InstallerResult -Context $Context -Type 'app-precheck' -Name $app -Status 'Missing' -Message $detection.Message
            }
        } catch {
            Write-InstallerLog -Context $Context -Message "Verificacao inicial falhou para '$app': $($_.Exception.Message)" -Level Error
            Add-InstallerResult -Context $Context -Type 'app-precheck' -Name $app -Status 'Failed' -Message $_.Exception.Message
        }
    }
}

function Invoke-InstallerTask {
    param($Context, [string]$TaskName)

    $taskPath = Join-Path $Context.RepositoryRoot "40-Tarefas\$TaskName.ps1"
    if (-not (Test-Path $taskPath)) { throw "Tarefa nao encontrada: $TaskName" }

    Write-InstallerLog -Context $Context -Message "Executando tarefa: $TaskName"
    # A tarefa deve usar throw para sinalizar falha.
    # LASTEXITCODE nao e verificado aqui porque ele pode conter o codigo
    # deixado por um executavel chamado em uma tarefa anterior.
    & $taskPath -Context $Context
}

function Get-ProfileRequiredAplicativos {
    param($Profile)

    $apps = @()
    if ($Profile.PSObject.Properties.Name -contains 'aplicativosObrigatorios') {
        $apps += @($Profile.aplicativosObrigatorios | ForEach-Object { [string]$_ })
    }
    elseif ($Profile.PSObject.Properties.Name -contains 'requiredAplicativos') {
        $apps += @($Profile.requiredAplicativos | ForEach-Object { [string]$_ })
    }
    elseif ($Profile.PSObject.Properties.Name -contains 'requiredApps') {
        $apps += @($Profile.requiredApps | ForEach-Object { [string]$_ })
    }
    return $apps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}


function Invoke-FinalAppVerification {
    param(
        $Context,
        [string[]]$RequiredAplicativos
    )

    foreach ($app in @($RequiredAplicativos)) {
        Register-RequiredApp `
            -Context $Context `
            -Name $app
    }

    $allRequired = @(
        Get-RequiredAplicativos -Context $Context |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            } |
            Select-Object -Unique
    )

    if ($allRequired.Count -eq 0) {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Nenhum aplicativo obrigatorio registrado para ' +
                'verificacao final.'
            )

        return @()
    }

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "AUDITORIA FINAL iniciada. Aplicativos planejados: " +
            "$($allRequired -join ', ')"
        )

    $missing = @()

    foreach ($app in $allRequired) {
        try {
            $manifest = Get-AppManifest `
                -Context $Context `
                -Name $app

            $displayName = [string](
                Get-ObjectPropertyValue `
                    -Object $manifest `
                    -Name 'displayName' `
                    -DefaultValue $app
            )

            $detection = Test-AppDetectedByManifest `
                -Context $Context `
                -Name $app `
                -Manifest $manifest

            if ($detection.Installed) {
                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        "Auditoria final: $displayName instalado. " +
                        "$($detection.Message)"
                    ) `
                    -Level Success
            }
            else {
                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        "Auditoria final: $displayName AUSENTE. " +
                        "$($detection.Message)"
                    ) `
                    -Level Warning

                $missing += $app
            }
        }
        catch {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "Auditoria final falhou ao verificar '$app': " +
                    "$($_.Exception.Message)"
                ) `
                -Level Error

            $missing += $app
        }
    }

    $missing = @(
        $missing |
            Select-Object -Unique
    )

    if ($missing.Count -eq 0) {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'AUDITORIA FINAL: todos os aplicativos planejados ' +
                'foram encontrados.'
            ) `
            -Level Success

        return @()
    }

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "AUDITORIA FINAL encontrou ausentes: " +
            "$($missing -join ', '). Somente eles serao reinstalados."
        ) `
        -Level Warning

    while ($missing.Count -gt 0) {
        $executedAttempt = $false

        foreach ($app in @($missing)) {
            $attemptsUsed = Get-AppInstallAttemptCount `
                -Context $Context `
                -Name $app

            if ($attemptsUsed -ge $Context.MaxInstallAttempts) {
                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        "Sem tentativas restantes para '$app'. " +
                        "Usadas: $attemptsUsed de " +
                        "$($Context.MaxInstallAttempts)."
                    ) `
                    -Level Error

                continue
            }

            $nextAttempt = $attemptsUsed + 1
            $executedAttempt = $true

            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "AUDITORIA FINAL: instalando novamente '$app'. " +
                    "Tentativa $nextAttempt de " +
                    "$($Context.MaxInstallAttempts)."
                ) `
                -Level Warning

            $null = Install-AppFromManifest `
                -Context $Context `
                -Name $app `
                -Attempt $nextAttempt
        }

        $stillMissing = @()

        foreach ($app in $allRequired) {
            if (
                -not (
                    Test-AppInstalledByName `
                        -Context $Context `
                        -Name $app
                )
            ) {
                $stillMissing += $app
            }
        }

        $missing = @(
            $stillMissing |
                Select-Object -Unique
        )

        if ($missing.Count -eq 0) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'AUDITORIA FINAL: todos os aplicativos foram ' +
                    'instalados apos as novas tentativas.'
                ) `
                -Level Success

            return @()
        }

        if (-not $executedAttempt) {
            break
        }

        $canRetry = $false

        foreach ($app in $missing) {
            $attemptsUsed = Get-AppInstallAttemptCount `
                -Context $Context `
                -Name $app

            if ($attemptsUsed -lt $Context.MaxInstallAttempts) {
                $canRetry = $true
                break
            }
        }

        if (-not $canRetry) {
            break
        }

        Write-InstallerLog `
            -Context $Context `
            -Message (
                "Ainda ausentes: $($missing -join ', '). " +
                "Uma nova rodada sera executada."
            ) `
            -Level Warning
    }

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "FALHA FINAL: aplicativos ainda ausentes depois de todas " +
            "as tentativas: $($missing -join ', ')"
        ) `
        -Level Error

    foreach ($missingApp in $missing) {
        [string]$missingApp
    }
}



function Invoke-AvisoManualFinalizacao {
    param(
        $Context,
        [ValidateSet('Sucesso','Pendencias')]
        [string]$Status = 'Sucesso',
        $MissingAplicativos = @(),
        $FailedTasks = @()
    )

    if ($null -eq $Context) { return }
    if ($Context.Mode -ne 'Manual') { return }

    $scriptPath = Join-Path $Context.RepositoryRoot '80-Recursos\Avisos\Mostrar-AvisoFinalManual.ps1'
    if (-not (Test-Path $scriptPath)) {
        Write-InstallerLog -Context $Context -Message "Aviso visual/sonoro manual nao encontrado: $scriptPath" -Level Warning
        return
    }

    if ($Status -eq 'Sucesso') {
        $mensagem = 'Instalacao manual finalizada. Valide os itens finais e continue o atendimento.'
    }
    else {
        $pendencias = @()
        if ($FailedTasks.Count -gt 0) { $pendencias += ('Tarefas com erro: ' + ($FailedTasks -join ', ')) }
        if ($MissingAplicativos.Count -gt 0) { $pendencias += ('Aplicativos pendentes: ' + ($MissingAplicativos -join ', ')) }
        if ($pendencias.Count -eq 0) { $pendencias += 'Existem pendencias registradas no log.' }
        $mensagem = 'Instalacao manual finalizada com pendencias. Verifique o log. ' + ($pendencias -join ' | ')
    }

    try {
        Write-InstallerLog -Context $Context -Message "Exibindo aviso visual/sonoro de finalizacao manual. Status: $Status."
        $argumentList = @(
            '-NoLogo',
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath,
            '-Mensagem', $mensagem,
            '-Status', $Status
        )
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -WindowStyle Hidden -PassThru -ErrorAction Stop
        $null = $process.WaitForExit(45000)
    } catch {
        Write-InstallerLog -Context $Context -Message "Falha ao exibir aviso visual/sonoro manual: $($_.Exception.Message)" -Level Warning
    }
}

Export-ModuleMember -Function *
