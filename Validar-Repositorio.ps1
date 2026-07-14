$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$errors = New-Object System.Collections.Generic.List[string]

function Add-ValidationError {
    param([string]$Message)
    $script:errors.Add($Message) | Out-Null
}

$requiredFiles = @(
    'VERSION.txt',
    'i.ps1',
    'Instalar-Manual-Web.ps1',
    'Instalar-Intune.ps1',
    'Executar-Instalador.ps1',
    '00-Inicializacao\00-IniciarInstalacaoGitHub.ps1',
    '00-Inicializacao\Executar-InstalacaoPersistente.ps1',
    '10-Nucleo\Instalador.Nucleo.psm1',
    '20-Configuracoes\Perfis\manual.json',
    '20-Configuracoes\Perfis\intunescheduled.json',
    '40-Tarefas\10-Seguranca-InstalarAgentesEmpresa.ps1',
    '40-Tarefas\50-Aplicativos-InstalarBase.ps1',
    '50-Integracoes\Topdesk\Get_Topdesk.ps1',
    '70-Deteccao\Detectar-PreparoIntune.ps1'
)

foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path (Join-Path $root $relativePath))) {
        Add-ValidationError "Arquivo obrigatorio ausente: $relativePath"
    }
}

foreach ($privatePath in @(
    '60-Segredos\topdesk-config.json',
    '60-Segredos\inventory-config.json'
)) {
    if (Test-Path (Join-Path $root $privatePath)) {
        Add-ValidationError "Arquivo privado publicado: $privatePath"
    }
}

foreach ($file in @(
    Get-ChildItem -Path $root -Recurse -File |
        Where-Object {
            $_.Extension -in @('.ps1', '.psm1') -and
            $_.Name -ne 'Get_Topdesk.ps1'
        }
)) {
    $tokens = $null
    $parseErrors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    foreach ($parseError in @($parseErrors)) {
        Add-ValidationError (
            "$($file.FullName) linha " +
            "$($parseError.Extent.StartLineNumber): " +
            $parseError.Message
        )
    }
}

foreach ($jsonFile in @(
    Get-ChildItem -Path $root -Recurse -File -Filter '*.json'
)) {
    try {
        Get-Content -Path $jsonFile.FullName -Raw -Encoding UTF8 |
            ConvertFrom-Json |
            Out-Null
    }
    catch {
        Add-ValidationError "JSON invalido: $($jsonFile.FullName)"
    }
}

foreach ($profileName in @('manual.json', 'intunescheduled.json')) {
    $profilePath = Join-Path `
        $root `
        "20-Configuracoes\Perfis\$profileName"

    if (-not (Test-Path $profilePath)) {
        continue
    }

    $profile = Get-Content -Path $profilePath -Raw -Encoding UTF8 |
        ConvertFrom-Json

    foreach ($taskName in @($profile.tarefas)) {
        if (
            -not (
                Test-Path (
                    Join-Path $root "40-Tarefas\$taskName.ps1"
                )
            )
        ) {
            Add-ValidationError (
                "$profileName referencia tarefa ausente: $taskName"
            )
        }
    }
}

$bootstrapContent = Get-Content `
    -Path (Join-Path $root '00-Inicializacao\00-IniciarInstalacaoGitHub.ps1') `
    -Raw `
    -Encoding UTF8

foreach ($requiredText in @(
    'archive/refs/heads/{1}.zip',
    'Invoke-RepositoryDownload',
    'Test-PowerShellSyntax',
    'Test-JsonFiles'
)) {
    if ($bootstrapContent -notmatch [regex]::Escape($requiredText)) {
        Add-ValidationError "Bootstrap sem trecho: $requiredText"
    }
}

foreach ($forbiddenText in @(
    'api.github.com',
    'Resolve-RepositoryReference',
    'codeload.github.com',
    'Validar-Repositorio.ps1 retornou'
)) {
    if ($bootstrapContent -match [regex]::Escape($forbiddenText)) {
        Add-ValidationError "Bootstrap contem complexidade removida: $forbiddenText"
    }
}

$runnerContent = Get-Content `
    -Path (Join-Path $root '00-Inicializacao\Executar-InstalacaoPersistente.ps1') `
    -Raw `
    -Encoding UTF8

foreach ($requiredText in @(
    'raw.githubusercontent.com',
    'Download-BootstrapWithInternetWait',
    'New-TimeSpan -Minutes 15',
    'intune_scheduled_completed.flag',
    'Disable-ScheduledTask'
)) {
    if ($runnerContent -notmatch [regex]::Escape($requiredText)) {
        Add-ValidationError "Executor persistente sem trecho: $requiredText"
    }
}

foreach ($forbiddenText in @(
    'shutdown.exe /r',
    'Autopilot-ReiniciarPrimeiroLogon',
    'WaitingForRestart'
)) {
    if ($runnerContent -match [regex]::Escape($forbiddenText)) {
        Add-ValidationError "Rotina de reinicio encontrada: $forbiddenText"
    }
}

$intuneProfile = Get-Content `
    -Path (Join-Path $root '20-Configuracoes\Perfis\intunescheduled.json') `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json

if (@($intuneProfile.aplicativosObrigatorios) -contains 'supportassist') {
    Add-ValidationError 'SupportAssist nao pode ser obrigatorio no Intune.'
}

$securityContent = Get-Content `
    -Path (Join-Path $root '40-Tarefas\10-Seguranca-InstalarAgentesEmpresa.ps1') `
    -Raw `
    -Encoding UTF8

$positions = @(
    $securityContent.IndexOf('$atlas,'),
    $securityContent.IndexOf("'journey'"),
    $securityContent.IndexOf('$sophos,'),
    $securityContent.IndexOf("'guardian'")
)

if (
    @($positions | Where-Object { $_ -lt 0 }).Count -gt 0 -or
    ($positions -join ',') -ne ((@($positions | Sort-Object)) -join ',')
) {
    Add-ValidationError (
        'A ordem Atlas, Journey, Sophos e Guardian esta incorreta.'
    )
}

$getTopdeskPath = Join-Path `
    $root `
    '50-Integracoes\Topdesk\Get_Topdesk.ps1'

if (Test-Path $getTopdeskPath) {
    $hash = (
        Get-FileHash -Path $getTopdeskPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    if (
        $hash -ne
        'c65b3b41ed4202a1aef3f7876bb522b8b955df80f6bb09fed4a2cbe745767793'
    ) {
        Add-ValidationError 'Get_Topdesk.ps1 foi alterado.'
    }
}

if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host 'VALIDACAO FALHOU:' -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host " - $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ''
Write-Host 'PACOTE VALIDADO COM SUCESSO.' -ForegroundColor Green
exit 0
