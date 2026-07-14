param(
  [string]$logPath,
  [string]$destino,

  [switch]$Silent,        # não pausa / sem interação (ideal para automação)
  [switch]$NoElevate,     # não tenta RunAs (se já está admin via CMD)
  [int]$InternetTimeoutSec = 180
)

# Se veio do seu script principal, assume silent automaticamente
if ($PSBoundParameters.ContainsKey('logPath') -or $PSBoundParameters.ContainsKey('destino')) {
  $Silent = $true
}

# =========================
# Configurações de Instalação (USADAS APENAS NA INSTALAÇÃO)
# =========================
$WebhookUrl  = 'https://n8n.atmis.com.br/webhook/4cdee70c-c395-40b0-9120-52371afeaf7e'
$WebhookUser = 'AdmWeb'
$WebhookPass = '@Imagem1232025'

# =========================
# Log opcional (integra com seu principal)
# =========================
function Escrever-LogLocal {
  param([string]$mensagem)
  try {
    $hora = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$hora - $mensagem"
    Write-Host $line
    if ($logPath) { $line | Out-File -FilePath $logPath -Append -Encoding utf8 }
  } catch {
    # não deixa log quebrar o script
    Write-Host $mensagem
  }
}

# =========================
# Auto-elevação (opcional)
# =========================
if (-not $NoElevate) {
  try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { $isAdmin = $false }

  if (-not $isAdmin) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Silent" -Verb RunAs
    exit 0
  }
}

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- FUNÇÕES UTILITÁRIAS ---

function Get-DiskInfo {
  $list = @()
  $pd = $null
  try { $pd = Get-PhysicalDisk } catch {}
  if ($pd -and $pd.Count -gt 0) {
    foreach ($d in $pd) {
      $disk = $null
      try { $disk = Get-Disk | Where-Object { $_.FriendlyName -eq $d.FriendlyName } } catch {}
      $iface = if ($disk) { $disk.BusType } else { $null }
      $list += [PSCustomObject]@{
        Numero = if ($disk) { $disk.Number } else { $null }
        Nome = $d.FriendlyName
        TipoMidia = if ($d.MediaType) { $d.MediaType.ToString() } else { 'Desconhecido' }
        Interface = if ($iface) { $iface.ToString() } else { 'Desconhecida' }
        TamanhoGB = if ($d.Size) { [Math]::Round($d.Size/1GB,2) } else { $null }
        Saude = $d.HealthStatus
      }
    }
  } else {
    $dd = Get-CimInstance Win32_DiskDrive
    foreach ($d in $dd) {
      $rot = $d.RotationRate
      $tipoMidia = if ($rot -eq 0 -or $rot -eq $null) { 'SSD' } else { 'HDD' }
      $disk = $null
      try { $disk = Get-Disk | Where-Object { $_.Number -eq $d.Index } } catch {}
      $bus = if ($disk) { $disk.BusType } else { $null }
      $list += [PSCustomObject]@{
        Numero = $d.Index
        Nome = $d.Model
        TipoMidia = $tipoMidia
        Interface = if ($bus) { $bus.ToString() } else { $d.InterfaceType }
        TamanhoGB = [Math]::Round($d.Size/1GB,2)
        Saude = 'N/D'
      }
    }
  }
  return $list
}

function Get-RamInfo {
  $modules = Get-CimInstance Win32_PhysicalMemory
  $total = ($modules | Measure-Object -Property Capacity -Sum).Sum
  $mods = $modules | ForEach-Object {
    [PSCustomObject]@{
      Fabricante = $_.Manufacturer
      Modelo = $_.PartNumber
      CapacidadeGB = [Math]::Round($_.Capacity/1GB,2)
      VelocidadeMHz = $_.Speed
    }
  }
  [PSCustomObject]@{
    TotalGB = [Math]::Round($total/1GB,2)
    Modulos = $mods
  }
}

function Get-RamSummary {
  $modules = Get-CimInstance Win32_PhysicalMemory
  $used = ($modules | Measure-Object).Count
  $totalSlots = 0
  $arrays = Get-CimInstance Win32_PhysicalMemoryArray
  foreach ($arr in $arrays) { if ($arr.MemoryDevices -gt 0) { $totalSlots += $arr.MemoryDevices } }
  if ($totalSlots -le 0) { $totalSlots = $used }
  $types = $modules | ForEach-Object {
    switch ($_.SMBIOSMemoryType) {
      34 { 'DDR5' }
      26 { 'DDR4' }
      24 { 'DDR3' }
      21 { 'DDR2' }
      20 { 'DDR' }
      default { $null }
    }
  } | Where-Object { $_ }
  if ($types -and $types.Count -gt 0) { $tipo = ($types | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name } else { $tipo = 'Desconhecido' }
  $total = ($modules | Measure-Object -Property Capacity -Sum).Sum
  [PSCustomObject]@{
    Tipo = $tipo
    Usados = $used
    Slots = $totalSlots
    TotalGB = [Math]::Round($total/1GB,2)
  }
}

function Load-ServiceConfig {
  $dir = $PSScriptRoot
  if (-not $dir) { $dir = (Get-Location).Path }
  $encPath = Join-Path $dir 'service_config.enc'

  if (Test-Path $encPath) {
    try {
      Add-Type -AssemblyName System.Security
      $b64 = Get-Content -Path $encPath -Raw
      $encBytes = [Convert]::FromBase64String($b64)
      $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect($encBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
      $json = [System.Text.Encoding]::UTF8.GetString($plainBytes)
      return ($json | ConvertFrom-Json)
    } catch {
      Escrever-LogLocal "Erro ao descriptografar config: $_"
      return $null
    }
  }
  return $null
}

function Aguardar-ConexaoInternet {
  param(
    [string]$TestUrl = 'http://www.google.com',
    [int]$MaxWaitSec = 180,
    [int]$IntervalSec = 5
  )
  Escrever-LogLocal "Aguardando conexão com a internet (timeout ${MaxWaitSec}s)..."

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $MaxWaitSec) {
    try {
      $null = Invoke-WebRequest -Uri $TestUrl -UseBasicParsing -Method Head -TimeoutSec 5 -ErrorAction Stop
      Escrever-LogLocal "Conexão estabelecida."
      return $true
    } catch {
      Escrever-LogLocal "Sem conexão ($($_.Exception.Message)). Tentando novamente em ${IntervalSec}s..."
      Start-Sleep -Seconds $IntervalSec
    }
  }

  Escrever-LogLocal "Timeout de internet atingido. Prosseguindo com falha controlada."
  return $false
}

function Invoke-AssetUpdate {
  param(
    [string]$PcName,
    [string]$RamText,
    [string]$StorageText,
    [string]$Url,
    [string]$User,
    [string]$Pass
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $pair = "${User}:${Pass}"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
  $base64 = [Convert]::ToBase64String($bytes)
  $headers = @{ Authorization = "Basic $base64" }

  $body = @{
    hostname  = $PcName
    ram       = $RamText
    storage   = $StorageText
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  } | ConvertTo-Json

  try {
    $resp = Invoke-RestMethod -Uri $Url -Method Post -Body $body -Headers $headers -ContentType 'application/json' -ErrorAction Stop
    Escrever-LogLocal "Dados enviados para o n8n com sucesso."
    return $true
  } catch {
    Escrever-LogLocal ("Falha ao enviar para n8n: {0}" -f $_)
    if ($_.Exception.Response) {
      try {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        Escrever-LogLocal ("Resposta do Servidor: " + $reader.ReadToEnd())
      } catch {}
    }
    return $false
  }
}

function Run-AgentLogic {
  $cfg = Load-ServiceConfig
  if (-not $cfg) { Escrever-LogLocal "Configuração não encontrada."; return 1 }

  $TargetUrl  = $cfg.url
  $TargetUser = $cfg.user
  $TargetPass = $cfg.pass

  if (-not $TargetUrl) { Escrever-LogLocal "URL do Webhook não encontrada."; return 1 }

  $okNet = Aguardar-ConexaoInternet -MaxWaitSec $InternetTimeoutSec
  if (-not $okNet) { return 2 }

  $device = Get-CimInstance Win32_ComputerSystem
  $pc = $device.Name

  $disks  = Get-DiskInfo
  $ram    = Get-RamInfo
  $ramSum = Get-RamSummary

  $summaryParts = @()
  foreach ($d in $disks) {
    $ifaceRaw = $d.Interface
    switch ($ifaceRaw) {
      'NVMe' { $iface = 'NVMe' }
      'SATA' { $iface = 'SATA' }
      'ATA'  { $iface = 'SATA' }
      'USB'  { $iface = 'USB' }
      default { $iface = if ($ifaceRaw) { $ifaceRaw } else { 'Desconhecido' } }
    }

    $tipoRaw = $d.TipoMidia
    $tipo = switch ($tipoRaw) {
      'SSD' { 'SSD' }
      'HDD' { 'HDD' }
      default { if ($tipoRaw) { $tipoRaw } else { 'Desconhecido' } }
    }

    $sizeInt = if ($d.TamanhoGB) { [Math]::Round($d.TamanhoGB) } else { 0 }
    $summaryParts += ('{0} {1} {2}GB' -f $tipo, $iface, $sizeInt)
  }

  $storageSummary = if ($summaryParts.Count -gt 0) { $summaryParts -join ' + ' } else { 'N/D' }
  $ramText = ('{0} {1}GB ({2}/{3})' -f $ramSum.Tipo, $ram.TotalGB, $ramSum.Usados, $ramSum.Slots)

  $currentState = @{ ram = $ramText; storage = $storageSummary }

  $stateFile = Join-Path $PSScriptRoot 'last_state.json'
  if (-not $PSScriptRoot) { $stateFile = Join-Path (Get-Location).Path 'last_state.json' }

  if (Test-Path $stateFile) {
    try {
      $lastState = Get-Content -Path $stateFile -Raw | ConvertFrom-Json
      if ($lastState.ram -eq $currentState.ram -and $lastState.storage -eq $currentState.storage) {
        Escrever-LogLocal "Nenhuma alteração detectada no hardware. Envio ignorado."
        return 0
      }
    } catch {
      Escrever-LogLocal "Arquivo de estado inválido. Prosseguindo com envio."
    }
  }

  $ok = Invoke-AssetUpdate -PcName $pc -RamText $ramText -StorageText $storageSummary -Url $TargetUrl -User $TargetUser -Pass $TargetPass

  if ($ok) {
    try { $currentState | ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8 } catch {}
    return 0
  } else {
    Escrever-LogLocal "Falha ao atualizar via API"
    return 1
  }
}

# --- LÓGICA DE INSTALAÇÃO OU EXECUÇÃO ---
$TaskName        = "TopdeskAssetUpdate"
$InstallDir      = "$env:ProgramData\TopdeskAut"
$AgentScriptName = "TopdeskAgent.ps1"
$AgentPath       = Join-Path $InstallDir $AgentScriptName
$CurrentScript   = $PSCommandPath

# Se estiver rodando do local de instalação, assume papel de AGENTE
if ($CurrentScript -eq $AgentPath) {
  Escrever-LogLocal "Modo Agente Iniciado."
  $code = Run-AgentLogic
  exit $code
}
else {
  # Modo INSTALADOR
  Escrever-LogLocal "--- INSTALADOR TOPDESK AGENT ---"

  if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Escrever-LogLocal "Diretorio criado: $InstallDir"
  }

  # 1) Gera service_config.enc
  $configData = @{ url = $WebhookUrl; user = $WebhookUser; pass = $WebhookPass }
  $jsonString = $configData | ConvertTo-Json
  $encPath = Join-Path $InstallDir 'service_config.enc'

  Add-Type -AssemblyName System.Security
  $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)
  $encBytes   = [System.Security.Cryptography.ProtectedData]::Protect($plainBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
  $b64        = [Convert]::ToBase64String($encBytes)
  Set-Content -Path $encPath -Value $b64 -Encoding ascii
  Escrever-LogLocal "Configuracao criptografada e salva em: $encPath"

  # 2) Gera o script do agente SEM credenciais em texto (corrige vazamento)
  $myContent = Get-Content -Path $CurrentScript -Raw

  $agentContent = $myContent `
    -replace '(?m)^\s*\$WebhookUrl\s*=.*$',  '$WebhookUrl  = $null' `
    -replace '(?m)^\s*\$WebhookUser\s*=.*$', '$WebhookUser = $null' `
    -replace '(?m)^\s*\$WebhookPass\s*=.*$', '$WebhookPass = $null'

  Set-Content -Path $AgentPath -Value $agentContent -Encoding utf8
  Escrever-LogLocal "Agente (limpo) instalado em: $AgentPath"

  # 3) Cria tarefa agendada
  $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $Task) {
    $Action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AgentPath`" -Silent -NoElevate"
    $Trigger   = New-ScheduledTaskTrigger -AtStartup
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal | Out-Null
    Escrever-LogLocal "Tarefa Agendada criada com sucesso."
  } else {
    Escrever-LogLocal "Tarefa Agendada ja existe."
  }

  Escrever-LogLocal "Instalacao Concluida."
  Escrever-LogLocal "Executando primeira atualizacao agora..."

  $p = Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AgentPath`" -Silent -NoElevate -InternetTimeoutSec $InternetTimeoutSec" -PassThru -Wait
  Escrever-LogLocal "Primeira execucao finalizada. ExitCode: $($p.ExitCode)"



  exit 0
}
