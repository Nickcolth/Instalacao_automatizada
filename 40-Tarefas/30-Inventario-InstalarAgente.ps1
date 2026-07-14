param($Context)

$ErrorActionPreference = 'Stop'

$originalScript = Join-Path `
    $Context.RepositoryRoot `
    '50-Integracoes\Topdesk\Get_Topdesk.ps1'

$expectedHash = 'c65b3b41ed4202a1aef3f7876bb522b8b955df80f6bb09fed4a2cbe745767793'

if (-not (Test-Path $originalScript)) {
    throw "Get_Topdesk.ps1 original nao encontrado em 50-Integracoes\Topdesk: $originalScript"
}

$actualHash = (
    Get-FileHash `
        -Path $originalScript `
        -Algorithm SHA256 `
        -ErrorAction Stop
).Hash.ToLowerInvariant()

if ($actualHash -ne $expectedHash) {
    throw (
        "O Get_Topdesk.ps1 preservado foi alterado. " +
        "Hash esperado: $expectedHash. " +
        "Hash encontrado: $actualHash."
    )
}

$tempDirectory = 'C:\Temp'

New-Item `
    -Path $tempDirectory `
    -ItemType Directory `
    -Force |
    Out-Null

Write-InstallerLog `
    -Context $Context `
    -Message (
        "Executando Get_Topdesk.ps1 preservado em 50-Integracoes\Topdesk. " +
        "SHA256 validado: $actualHash"
    )

$arguments = @(
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    ('"' + $originalScript + '"')
    '-logPath'
    ('"' + $Context.LogPath + '"')
    '-destino'
    ('"' + $tempDirectory + '"')
) -join ' '

$exitCode = Invoke-WithTimeout `
    -Context $Context `
    -FilePath 'powershell.exe' `
    -ArgumentList $arguments `
    -TimeoutSeconds 1200 `
    -Name 'Get_Topdesk original'

if ($exitCode -ne 0) {
    throw "Get_Topdesk.ps1 original retornou o codigo $exitCode."
}

$installDirectory = Join-Path `
    $env:ProgramData `
    'TopdeskAut'

$agentPath = Join-Path `
    $installDirectory `
    'TopdeskAgent.ps1'

$encryptedConfigPath = Join-Path `
    $installDirectory `
    'service_config.enc'

$scheduledTask = Get-ScheduledTask `
    -TaskName 'TopdeskAssetUpdate' `
    -ErrorAction SilentlyContinue

if (-not (Test-Path $agentPath)) {
    throw "O agente original nao foi criado: $agentPath"
}

if (-not (Test-Path $encryptedConfigPath)) {
    throw (
        "A configuracao original nao foi criada: " +
        "$encryptedConfigPath"
    )
}

if ($null -eq $scheduledTask) {
    throw (
        "A tarefa agendada original nao foi criada: " +
        "TopdeskAssetUpdate"
    )
}

$actionText = @(
    $scheduledTask.Actions |
        ForEach-Object {
            "$($_.Execute) $($_.Arguments)"
        }
) -join ' '

if ($actionText -notmatch 'TopdeskAgent\.ps1') {
    throw (
        "A tarefa TopdeskAssetUpdate existe, mas nao aponta para " +
        "TopdeskAgent.ps1."
    )
}

Write-InstallerLog `
    -Context $Context `
    -Message (
        "Get_Topdesk original instalado e validado. " +
        "Agente: $agentPath. " +
        "Configuracao: $encryptedConfigPath. " +
        "Tarefa: TopdeskAssetUpdate."
    ) `
    -Level Success

Add-InstallerResult `
    -Context $Context `
    -Type 'task' `
    -Name 'Inventario' `
    -Status 'Success' `
    -Message (
        "Get_Topdesk original executado a partir de 50-Integracoes\Topdesk, " +
        "sem qualquer alteracao."
    )
