[CmdletBinding()]
param(
    [ValidateSet('Auto','Manual','IntuneCritical','IntuneScheduled')]
    [string]$Mode = 'Auto',

    [string]$Repository = 'Nickcolth/Instalacao_automatizada',

    [string]$Branch = 'main',

    [string]$PackageVersion = 'sem-versao',

    [string]$WorkingDirectory = "$env:ProgramData\ImagemTI\Instalador",

    [string]$SecureRoot = "$env:ProgramData\ImagemTI\Instalador\Segredos",

    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12
}
catch {}

function Write-BootstrapLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )

    $logDirectory = Join-Path $WorkingDirectory 'Logs'
    New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null

    $line = '{0} [{1}] {2}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
        $Level, `
        $Message

    $line | Out-File `
        -FilePath (Join-Path $logDirectory 'intune-bootstrap.log') `
        -Append `
        -Encoding utf8

    Write-Host $line
}

function Test-IsSystem {
    try {
        return [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
    }
    catch {
        return $false
    }
}

function Resolve-ExecutionMode {
    param([string]$RequestedMode)

    if ($RequestedMode -ne 'Auto') {
        return $RequestedMode
    }

    if (Test-IsSystem) {
        return 'IntuneScheduled'
    }

    return 'Manual'
}

function Get-UserNameOnly {
    param([string]$IdentityName)

    if ([string]::IsNullOrWhiteSpace($IdentityName)) {
        return ''
    }

    if ($IdentityName -like '*\*') {
        return (($IdentityName -split '\\')[-1])
    }

    return $IdentityName
}

function Get-InteractiveUsers {
    $users = New-Object System.Collections.Generic.List[string]

    try {
        $computerSystem = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop

        if ($computerSystem.UserName) {
            $users.Add([string]$computerSystem.UserName) | Out-Null
        }
    }
    catch {}

    try {
        foreach ($process in @(
            Get-Process `
                -Name explorer `
                -IncludeUserName `
                -ErrorAction SilentlyContinue
        )) {
            if ($process.UserName) {
                $users.Add([string]$process.UserName) | Out-Null
            }
        }
    }
    catch {}

    return @(
        $users |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            } |
            Sort-Object -Unique
    )
}

function Assert-InteractiveUserAllowed {
    $blocked = $false

    if (Test-IsSystem) {
        foreach ($user in @(Get-InteractiveUsers)) {
            if ((Get-UserNameOnly -IdentityName $user) -ieq 'Imagem') {
                $blocked = $true
                break
            }
        }
    }
    else {
        $blocked = (
            (Get-UserNameOnly -IdentityName $env:USERNAME) -ieq 'Imagem'
        )
    }

    if (-not $blocked) {
        return
    }

    $flagDirectory = Join-Path $WorkingDirectory 'Flags'
    New-Item -Path $flagDirectory -ItemType Directory -Force | Out-Null

    Set-Content `
        -Path (Join-Path $flagDirectory 'bloqueado_usuario_imagem.flag') `
        -Value (Get-Date -Format o) `
        -Encoding ASCII `
        -Force

    throw 'Execucao bloqueada porque o usuario Imagem esta conectado.'
}

function Test-ZipFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    $item = Get-Item -Path $Path -ErrorAction Stop

    if ($item.Length -lt 1024) {
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

    return ($first -eq 0x50 -and $second -eq 0x4B)
}

function Invoke-RepositoryDownload {
    param(
        [string]$Uri,
        [string]$Destination,
        [int]$MaximumAttempts = 3
    )

    $lastError = ''

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        Remove-Item `
            -Path $Destination `
            -Force `
            -ErrorAction SilentlyContinue

        try {
            Write-BootstrapLog (
                "Download do repositorio: tentativa $attempt de " +
                "$MaximumAttempts."
            )

            try {
                Invoke-WebRequest `
                    -Uri $Uri `
                    -OutFile $Destination `
                    -UseBasicParsing `
                    -TimeoutSec 900 `
                    -Headers @{
                        'User-Agent' = 'ImagemTI-Instalador'
                        'Cache-Control' = 'no-cache'
                        'Pragma' = 'no-cache'
                    } `
                    -ErrorAction Stop
            }
            catch {
                Start-BitsTransfer `
                    -Source $Uri `
                    -Destination $Destination `
                    -ErrorAction Stop
            }

            if (-not (Test-ZipFile -Path $Destination)) {
                throw 'O arquivo recebido nao e um ZIP valido.'
            }

            $length = (
                Get-Item -Path $Destination -ErrorAction Stop
            ).Length

            Write-BootstrapLog `
                -Message "Repositorio baixado: $length bytes." `
                -Level 'SUCCESS'

            return
        }
        catch {
            $lastError = $_.Exception.Message

            Write-BootstrapLog `
                -Message (
                    "Falha no download, tentativa ${attempt}: " +
                    $lastError
                ) `
                -Level 'WARN'

            if ($attempt -lt $MaximumAttempts) {
                Start-Sleep -Seconds (10 * $attempt)
            }
        }
    }

    throw (
        'Nao foi possivel baixar o repositorio. Ultimo erro: ' +
        $lastError
    )
}

function Test-PowerShellSyntax {
    param([string]$RootPath)

    $errorsFound = @()
    $files = @(
        Get-ChildItem `
            -Path $RootPath `
            -Recurse `
            -File `
            -ErrorAction Stop |
            Where-Object {
                $_.Extension -in @('.ps1', '.psm1') -and
                $_.Name -ne 'Get_Topdesk.ps1' -and
                $_.FullName -notmatch '[\\/]60-Segredos[\\/]'
            }
    )

    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null

        [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        foreach ($parseError in @($parseErrors)) {
            $errorsFound += (
                "$($file.FullName) linha " +
                "$($parseError.Extent.StartLineNumber): " +
                $parseError.Message
            )
        }
    }

    if ($errorsFound.Count -gt 0) {
        foreach ($syntaxError in $errorsFound) {
            Write-BootstrapLog `
                -Message "SINTAXE: $syntaxError" `
                -Level 'ERROR'
        }

        throw (
            'O repositorio possui erro de sintaxe. Total: ' +
            $errorsFound.Count
        )
    }

    Write-BootstrapLog `
        -Message (
            'Validacao de sintaxe concluida. Scripts: ' +
            $files.Count
        ) `
        -Level 'SUCCESS'
}

function Test-JsonFiles {
    param([string]$RootPath)

    foreach ($file in @(
        Get-ChildItem `
            -Path $RootPath `
            -Recurse `
            -File `
            -Filter '*.json' `
            -ErrorAction Stop
    )) {
        try {
            Get-Content `
                -Path $file.FullName `
                -Raw `
                -Encoding UTF8 |
                ConvertFrom-Json |
                Out-Null
        }
        catch {
            throw "JSON invalido: $($file.FullName)"
        }
    }

    Write-BootstrapLog `
        -Message 'Validacao dos arquivos JSON concluida.' `
        -Level 'SUCCESS'
}

function Test-EssentialRepositoryFiles {
    param(
        [string]$RepositoryRoot,
        [string]$ResolvedMode
    )

    $requiredFiles = @(
        'Executar-Instalador.ps1',
        '10-Nucleo\Instalador.Nucleo.psm1',
        '20-Configuracoes\Perfis\manual.json',
        '20-Configuracoes\Perfis\intunecritical.json',
        '20-Configuracoes\Perfis\intunescheduled.json'
    )

    foreach ($relativePath in $requiredFiles) {
        $path = Join-Path $RepositoryRoot $relativePath

        if (-not (Test-Path $path)) {
            throw "Arquivo essencial ausente: $relativePath"
        }
    }

    $profileName = if ($ResolvedMode -eq 'Manual') {
        'manual.json'
    }
    elseif ($ResolvedMode -eq 'IntuneCritical') {
        'intunecritical.json'
    }
    else {
        'intunescheduled.json'
    }

    $profilePath = Join-Path `
        $RepositoryRoot `
        "20-Configuracoes\Perfis\$profileName"

    $profile = Get-Content `
        -Path $profilePath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json

    foreach ($taskName in @($profile.tarefas)) {
        $taskPath = Join-Path `
            $RepositoryRoot `
            "40-Tarefas\$taskName.ps1"

        if (-not (Test-Path $taskPath)) {
            throw (
                "$profileName referencia tarefa ausente: $taskName"
            )
        }
    }
}

function Copy-SecureFiles {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path $Source)) {
        return
    }

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    Copy-Item `
        -Path (Join-Path $Source '*') `
        -Destination $Destination `
        -Recurse `
        -Force `
        -ErrorAction Stop
}

function Get-RepositoryVersion {
    param([string]$RepositoryRoot)

    $versionPath = Join-Path $RepositoryRoot 'VERSION.txt'

    if (-not (Test-Path $versionPath)) {
        return $PackageVersion
    }

    $version = (
        Get-Content `
            -Path $versionPath `
            -Raw `
            -Encoding UTF8
    ).Trim()

    if ([string]::IsNullOrWhiteSpace($version)) {
        return $PackageVersion
    }

    return $version
}

function Set-InstallerState {
    param(
        [string]$Status,
        [string]$Message,
        [int]$ExitCode = -999999,
        [string]$RepositoryVersion = ''
    )

    $registryPath = 'HKLM:\SOFTWARE\ImagemTI\Instalador'
    New-Item -Path $registryPath -ItemType Directory -Force | Out-Null

    $values = @{
        Status = $Status
        LastMessage = $Message
        LastRunTime = (Get-Date).ToString('o')
        Repository = $Repository
        Branch = $Branch
        IntuneBootstrapVersion = $PackageVersion
    }

    if (-not [string]::IsNullOrWhiteSpace($RepositoryVersion)) {
        $values['LastRepositoryVersion'] = $RepositoryVersion
    }

    if ($ExitCode -ne -999999) {
        $values['LastExitCode'] = [string]$ExitCode
    }

    foreach ($name in $values.Keys) {
        New-ItemProperty `
            -Path $registryPath `
            -Name $name `
            -Value ([string]$values[$name]) `
            -PropertyType String `
            -Force |
            Out-Null
    }
}

function Remove-OldRunDirectories {
    param(
        [string]$Root,
        [string]$CurrentRun,
        [int]$MaximumAgeDays = 14
    )

    $limit = (Get-Date).AddDays(-1 * $MaximumAgeDays)

    foreach ($directory in @(
        Get-ChildItem `
            -Path $Root `
            -Directory `
            -ErrorAction SilentlyContinue
    )) {
        if ($directory.FullName -eq $CurrentRun) {
            continue
        }

        if (
            $directory.Name -match '^\d{8}-\d{6}$' -and
            $directory.LastWriteTime -lt $limit
        ) {
            Remove-Item `
                -Path $directory.FullName `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

$resolvedMode = Resolve-ExecutionMode -RequestedMode $Mode
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$runRoot = Join-Path $WorkingDirectory $runId
$zipPath = Join-Path $runRoot 'repository.zip'
$extractPath = Join-Path $runRoot 'source'

New-Item `
    -Path $WorkingDirectory, $runRoot, $extractPath `
    -ItemType Directory `
    -Force |
    Out-Null

Remove-OldRunDirectories `
    -Root $WorkingDirectory `
    -CurrentRun $runRoot

try {
    Assert-InteractiveUserAllowed

    Set-InstallerState `
        -Status 'Downloading' `
        -Message 'Baixando o branch atual do repositorio.'

    $encodedBranch = [Uri]::EscapeDataString($Branch)

    $archiveUrl = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        'https://github.com/{0}/archive/refs/heads/{1}.zip',
        $Repository,
        $encodedBranch
    )

    Write-BootstrapLog (
        "Iniciando execucao. Modo: $resolvedMode. Repositorio: " +
        "$Repository. Branch: $Branch."
    )

    Write-BootstrapLog -Message "Baixando: $archiveUrl"

    Invoke-RepositoryDownload `
        -Uri $archiveUrl `
        -Destination $zipPath

    Expand-Archive `
        -Path $zipPath `
        -DestinationPath $extractPath `
        -Force

    $repositoryRoot = Get-ChildItem `
        -Path $extractPath `
        -Directory `
        -ErrorAction Stop |
        Select-Object -First 1

    if (-not $repositoryRoot) {
        throw 'Nao foi possivel localizar a pasta extraida.'
    }

    $duplicateModule = Join-Path `
        $repositoryRoot.FullName `
        'Instalador.Nucleo.psm1'

    if (Test-Path $duplicateModule) {
        Remove-Item `
            -Path $duplicateModule `
            -Force `
            -ErrorAction SilentlyContinue

        Write-BootstrapLog `
            -Message 'Modulo duplicado da raiz foi ignorado.' `
            -Level 'WARN'
    }

    Copy-SecureFiles `
        -Source $SecureRoot `
        -Destination (Join-Path $repositoryRoot.FullName '60-Segredos')

    Test-EssentialRepositoryFiles `
        -RepositoryRoot $repositoryRoot.FullName `
        -ResolvedMode $resolvedMode

    Test-PowerShellSyntax -RootPath $repositoryRoot.FullName
    Test-JsonFiles -RootPath $repositoryRoot.FullName

    $repositoryVersion = Get-RepositoryVersion `
        -RepositoryRoot $repositoryRoot.FullName

    Write-BootstrapLog `
        -Message "Versao: $repositoryVersion" `
        -Level 'SUCCESS'

    Set-InstallerState `
        -Status 'Running' `
        -Message 'Repositorio validado. Iniciando o instalador.' `
        -RepositoryVersion $repositoryVersion

    $entryPoint = Join-Path `
        $repositoryRoot.FullName `
        'Executar-Instalador.ps1'

    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $entryPoint `
        -Mode $resolvedMode `
        -RepositoryRoot $repositoryRoot.FullName `
        -PackageVersion $repositoryVersion

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Set-InstallerState `
            -Status 'Failed' `
            -Message "Instalador retornou codigo $exitCode." `
            -ExitCode $exitCode `
            -RepositoryVersion $repositoryVersion

        Write-BootstrapLog `
            -Message "Instalador finalizou com codigo $exitCode." `
            -Level 'ERROR'

        exit $exitCode
    }

    Set-InstallerState `
        -Status 'Completed' `
        -Message 'Instalacao corporativa concluida.' `
        -ExitCode 0 `
        -RepositoryVersion $repositoryVersion

    Write-BootstrapLog `
        -Message 'Instalacao corporativa concluida com sucesso.' `
        -Level 'SUCCESS'

    if (-not $KeepFiles) {
        Remove-Item `
            -Path $runRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    exit 0
}
catch {
    $message = $_.Exception.Message

    Set-InstallerState `
        -Status 'Failed' `
        -Message $message `
        -ExitCode 1

    Write-BootstrapLog `
        -Message "Falha critica no bootstrap: $message" `
        -Level 'ERROR'

    if ($_.ScriptStackTrace) {
        Write-BootstrapLog `
            -Message $_.ScriptStackTrace `
            -Level 'ERROR'
    }

    Write-BootstrapLog `
        -Message "Arquivos preservados para diagnostico: $runRoot" `
        -Level 'WARN'

    exit 1
}
