param($Context)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $Context.RepositoryRoot '50-Integracoes\Znuny\Znuny.Api.ps1')

function Test-ImagemEmSessao {
    param([string]$NomeConta)
    $nomes = @()
    try { $nomes += [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch {}
    if ($env:USERNAME) { $nomes += $env:USERNAME }
    try {
        $sessaoConsole = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($sessaoConsole) { $nomes += $sessaoConsole }
    } catch {}
    try {
        foreach ($linha in @(quser.exe 2>$null)) {
            if ([string]$linha -match '^\s*>?\s*([^\s]+)\s+') { $nomes += $Matches[1] }
        }
    } catch {}
    foreach ($nome in $nomes) {
        $usuario = (([string]$nome -split '\\')[-1] -split '@')[0]
        if ($usuario -ieq $NomeConta) { return $true }
    }
    return $false
}

function Get-RegistryIntValue {
    param([object]$Object, [string]$Name, [int]$Default = 0)
    try {
        if ($null -eq $Object) { return $Default }
        if ($null -eq $Object.PSObject.Properties[$Name]) { return $Default }
        return [int]$Object.$Name
    } catch { return $Default }
}

function Get-RegistryStringValue {
    param([object]$Object, [string]$Name)
    try {
        if ($null -eq $Object) { return '' }
        if ($null -eq $Object.PSObject.Properties[$Name]) { return '' }
        return [string]$Object.$Name
    } catch { return '' }
}

function Test-LapsGerenciaContaImagem {
    param([string]$AccountName = 'Imagem')

    $lapsPolicyPath = 'HKLM:\Software\Microsoft\Policies\LAPS'
    if (-not (Test-Path $lapsPolicyPath)) { return $false }

    try {
        $lapsPolicy = Get-ItemProperty -Path $lapsPolicyPath -ErrorAction Stop
    } catch { return $false }

    # BackupDirectory: 0 = Disabled, 1 = Microsoft Entra ID, 2 = Active Directory
    $backupDirectory = Get-RegistryIntValue -Object $lapsPolicy -Name 'BackupDirectory' -Default 0
    if ($backupDirectory -le 0) { return $false }

    # Windows LAPS com gerenciamento automatico de conta.
    $autoEnabled = Get-RegistryIntValue -Object $lapsPolicy -Name 'AutomaticAccountManagementEnabled' -Default 0
    if ($autoEnabled -eq 1) {
        $nameOrPrefix = Get-RegistryStringValue -Object $lapsPolicy -Name 'AutomaticAccountManagementNameOrPrefix'
        $randomize    = Get-RegistryIntValue -Object $lapsPolicy -Name 'AutomaticAccountManagementRandomizeName' -Default 0

        if ($nameOrPrefix -ieq $AccountName -and $randomize -ne 1) {
            return $true
        }
    }

    # Windows LAPS gerenciando uma conta customizada existente.
    $managedAccountName = Get-RegistryStringValue -Object $lapsPolicy -Name 'AdministratorAccountName'
    if ($managedAccountName -ieq $AccountName) { return $true }

    return $false
}

function Get-AdministratorsGroupName {
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        return ($sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1])
    } catch { return 'Administradores' }
}

function Get-RandomLetter  { 'abcdefghijkmnopqrstuvwxyz'[(Get-Random -Minimum 0 -Maximum 25)] }
function Get-RandomLetterH { 'ABCDEFGHIJKLMNPQRSTUVWXYZ'[(Get-Random -Minimum 0 -Maximum 25)] }
function Get-RandomSpecial { '!@#$%&*'[(Get-Random -Minimum 0 -Maximum 7)] }
function Get-RandomNumber  { Get-Random -Minimum 0 -Maximum 10 }

function New-GeneratedPassword {
    return "$(Get-RandomLetter)$(Get-RandomNumber)$(Get-RandomNumber)$(Get-RandomLetter)$(Get-RandomNumber)$(Get-RandomNumber)$(Get-RandomLetterH)$(Get-RandomSpecial)$(Get-RandomSpecial)"
}

function Get-RandomString {
    param([int]$Length)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Length; $i++) {
        $null = $sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
    }
    return $sb.ToString()
}

function Get-ImagemProfilePath {
    param([string]$AccountName)
    try {
        $user = Get-LocalUser -Name $AccountName -ErrorAction Stop
        $sid  = $user.SID.Value
        $regPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        if (Test-Path $regPath) {
            $profilePath = (Get-ItemProperty -Path $regPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
            if ($profilePath -and (Test-Path $profilePath)) { return $profilePath }
        }
    } catch {}
    return $null
}

function Get-LocalBackupFolders {
    param($Context, [string]$AccountName)

    $folders = New-Object System.Collections.Generic.List[string]
    $folders.Add('C:\Program Files\IMG') | Out-Null
    $folders.Add('C:\ProgramData\IMG') | Out-Null

    $profilePath = Get-ImagemProfilePath -AccountName $AccountName
    if ($profilePath) {
        $folders.Add((Join-Path $profilePath 'AppData\Local\IMG')) | Out-Null
    } else {
        Write-InstallerLog -Context $Context -Message "Perfil do usuario '$AccountName' ainda nao existe; backup no perfil sera ignorado por enquanto." -Level Warning
    }

    return $folders.ToArray()
}

function Ensure-Folder {
    param([string]$Path)
    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
}

function Write-ObfuscatedLine {
    param($Context, [string]$Pc, [string]$Line, [string]$AccountName)

    $folders = Get-LocalBackupFolders -Context $Context -AccountName $AccountName
    $okPaths = New-Object System.Collections.Generic.List[string]
    $errors  = New-Object System.Collections.Generic.List[string]

    foreach ($folder in $folders) {
        try {
            Ensure-Folder -Path $folder
            $file = Join-Path -Path $folder -ChildPath "$Pc.txt"
            if (-not (Test-Path $file)) {
                New-Item -Path $file -ItemType File -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $file -Value $Line -Encoding UTF8 -ErrorAction Stop
            if (-not (Test-Path -Path $file)) { throw "Arquivo nao existe apos escrita: $file" }
            $okPaths.Add($file) | Out-Null
        } catch {
            $errors.Add("Falhou em '$folder' -> $($_.Exception.Message)") | Out-Null
            continue
        }
    }

    if ($okPaths.Count -eq 0) { throw ([System.Exception]::new(($errors -join ' | '))) }
    return $okPaths.ToArray()
}

function Write-LocalObfuscatedBackupUser {
    param($Context, [string]$Pc, [string]$Password, [string]$AccountName, [string]$Stage = 'GERADA')

    $datahora = Get-Date -Format 'yyyyMMddHHmmss'
    $line = "asjdnbe8c84jbnfa9fasg${datahora}${Stage}${Password}kcne" + (Get-Random -Minimum 10000 -Maximum 99999)
    if ($line.Length -lt 130) { $line += Get-RandomString (130 - $line.Length) }
    Write-ObfuscatedLine -Context $Context -Pc $Pc -Line $line -AccountName $AccountName
}

function Write-LocalObfuscatedBackupBiosIfOk {
    param($Context, [string]$Pc, [string]$SenhaBios, [bool]$BiosOk, [string]$AccountName, [string]$Stage = 'FINAL')

    if (-not $BiosOk) { return $null }
    if ([string]::IsNullOrWhiteSpace($SenhaBios)) { return $null }
    if ($SenhaBios -eq 'N/C') { return $null }
    if ($SenhaBios -eq 'BIOS nao alterada pelo script') { return $null }

    $datahora = Get-Date -Format 'yyyyMMddHHmmss'
    $line = "pqoweiuf098asfbiopzzyx${datahora}${Stage}${SenhaBios}ffh4l" + (Get-Random -Minimum 10000 -Maximum 99999)
    if ($line.Length -lt 130) { $line += Get-RandomString (130 - $line.Length) }
    Write-ObfuscatedLine -Context $Context -Pc $Pc -Line $line -AccountName $AccountName
}

function Get-SafePropertyValue {
    param(
        $Object,
        [string[]]$Names
    )

    if ($null -eq $Object) { return $null }

    foreach ($Name in $Names) {
        $Property = $Object.PSObject.Properties[$Name]

        if ($null -ne $Property -and $null -ne $Property.Value) {
            return $Property.Value
        }
    }

    return $null
}

function Get-ConfigString {
    param($Config, [string]$Name, [string]$Default)
    if ($null -eq $Config) { return $Default }
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}

function Get-ConfigBool {
    param($Config, [string]$Name, [bool]$Default)
    if ($null -eq $Config) { return $Default }
    if ($Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name) {
        return [bool]$Config.$Name
    }
    return $Default
}

function Get-ConfigInt {
    param($Config, [string]$Name, [int]$Default)
    if ($null -eq $Config) { return $Default }
    if ($Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name) {
        try { return [int]$Config.$Name } catch { return $Default }
    }
    return $Default
}

function Write-NetworkBackup {
    param(
        $Context,
        $Config,
        [string]$Pc,
        [string]$SenhaImagemParaRegistro,
        [string]$SenhaBiosParaRegistro
    )

    $logFolder = Get-ConfigString -Config $Config -Name 'networkBackupPath' -Default '\\fileserver\SDK\Softwares\Instalacao_automatizada\logsenha'
    if ([string]::IsNullOrWhiteSpace($logFolder) -or $logFolder -eq 'disabled') {
        Write-InstallerLog -Context $Context -Message 'Backup de rede desabilitado pela configuracao.'
        return
    }

    $networkTimeoutSeconds = Get-ConfigInt -Config $Config -Name 'networkBackupTimeoutSeconds' -Default 5

    try {
        $testJob = Start-Job -ScriptBlock { param($Path) Test-Path -Path $Path } -ArgumentList $logFolder
        $finished = Wait-Job -Job $testJob -Timeout $networkTimeoutSeconds

        if (-not $finished) {
            Stop-Job -Job $testJob -Force -ErrorAction SilentlyContinue
            Remove-Job -Job $testJob -Force -ErrorAction SilentlyContinue
            Write-InstallerLog -Context $Context -Message "Caminho de rede nao respondeu em $networkTimeoutSeconds segundos. Backup ignorado: $logFolder" -Level Warning
            return
        }

        $networkPathExists = Receive-Job -Job $testJob -ErrorAction SilentlyContinue
        Remove-Job -Job $testJob -Force -ErrorAction SilentlyContinue

        if (-not $networkPathExists) {
            Write-InstallerLog -Context $Context -Message "A pasta de log de rede nao existe ou nao esta acessivel. Backup ignorado: $logFolder" -Level Warning
            return
        }

        $logFile = Join-Path -Path $logFolder -ChildPath "$Pc.txt"
        $logContent = @"
==============================
Data e hora: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
Computador: $Pc
Senha usuario imagem: $SenhaImagemParaRegistro
Senha Admin da BIOS: $SenhaBiosParaRegistro
==============================
"@
        $logContent | Out-File -FilePath $logFile -Encoding UTF8 -Append -ErrorAction Stop
        Write-InstallerLog -Context $Context -Message "Backup da senha criado em $logFile"
    } catch {
        Write-InstallerLog -Context $Context -Message "Erro ao gravar o log de rede. Backup ignorado: detalhes sensiveis omitidos" -Level Warning
    }
}

$znunyConfig = Get-ZnunyConfig -Context $Context
$pc = $env:COMPUTERNAME
$accountName = Get-ConfigString -Config $znunyConfig -Name 'imageAccountName' -Default 'Imagem'
$imagePasswordFieldName = 'SenhaUsuarioImagem'
$biosPasswordFieldName = 'SenhaBios'
$lapsFieldValue = Get-ConfigString -Config $znunyConfig -Name 'lapsFieldValue' -Default 'Gerenciado via LAPS'

$imagemGerenciadaPeloLaps = Test-LapsGerenciaContaImagem -AccountName $accountName

if ($Context.IsIntune) {
    if ($imagemGerenciadaPeloLaps) {
        Write-InstallerLog -Context $Context -Message "Windows LAPS detectado gerenciando a conta '$accountName'."
    } else {
        Write-InstallerLog -Context $Context -Message "Politica do Windows LAPS ainda nao foi detectada localmente, mas o modo Intune registrara '$lapsFieldValue' no Znuny conforme perfil Autopilot." -Level Warning
    }

    try {
        $registered = Send-ZnunyAssetFields `
            -Context $Context `
            -Config $znunyConfig `
            -ComputerName $pc `
            -Fields @{ $imagePasswordFieldName = $lapsFieldValue }

        if ($registered) {
            Write-InstallerLog `
                -Context $Context `
                -Message "Znuny registrado como '$lapsFieldValue'." `
                -Level Success
        }
    }
    catch {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Nao foi possivel atualizar o Znuny durante o ' +
                "Autopilot. A instalacao continuara. Erro: $($_.Exception.Message)"
            ) `
            -Level Warning
    }

    Write-InstallerLog `
        -Context $Context `
        -Message (
            "Modo Intune: usuario '$accountName' nao foi criado/alterado " +
            'e a BIOS nao foi alterada.'
        )

    return
}

$imagemEmSessao = Test-ImagemEmSessao -NomeConta $accountName
if ($imagemEmSessao) {
    Write-InstallerLog -Context $Context -Message "Usuario '$accountName' esta conectado. A senha da conta sera preservada." -Level Warning
}

$password = $null
$securePass = $null
$senhaBios = $null
$senhaBiosParaRegistro = 'BIOS nao alterada pelo script'
$senhaImagemParaRegistro = $null
$biosAlteradaPeloScript = $false
$imagemProntaParaRegistro = $false

try {
    $password = New-GeneratedPassword
    $senhaBios = $password
    Write-InstallerLog -Context $Context -Message "Senha gerada para provisionamento manual do notebook: $pc"

    $usuarioImagem = Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue

    if ($imagemEmSessao) {
        $senhaImagemParaRegistro = 'NAO ALTERADA - CONTA EM USO'
        Write-InstallerLog -Context $Context -Message "Criacao e alteracao de senha de '$accountName' ignoradas: conta em uso."
    } elseif ($imagemGerenciadaPeloLaps) {
        $senhaImagemParaRegistro = $lapsFieldValue
        $imagemProntaParaRegistro = $true

        if ($null -ne $usuarioImagem) {
            Write-InstallerLog -Context $Context -Message "Windows LAPS esta configurado para gerenciar a conta '$accountName' e a conta ja existe. Nenhuma alteracao sera feita na conta ou senha."
        } else {
            $createBackup = Get-ConfigBool -Config $znunyConfig -Name 'createImageAccountAsBackupWhenLapsDetected' -Default $true
            if ($createBackup) {
                Write-InstallerLog -Context $Context -Message "Windows LAPS esta configurado para gerenciar '$accountName', mas a conta ainda nao existe. Criando conta como backup com senha temporaria."
                try {
                    $securePass = ConvertTo-SecureString $password -AsPlainText -Force
                    New-LocalUser -Name $accountName -Password $securePass -FullName $accountName -Description 'Conta local de suporte. Gerenciada pelo Windows LAPS.' -PasswordNeverExpires -UserMayNotChangePassword:$true -ErrorAction Stop
                    Write-InstallerLog -Context $Context -Message "Usuario '$accountName' criado como backup. A senha temporaria nao sera registrada, pois a conta e gerenciada pelo LAPS."
                } catch {
                    Write-InstallerLog -Context $Context -Message "Erro ao criar o usuario '$accountName' como backup: detalhes sensiveis omitidos" -Level Warning
                }
            } else {
                Write-InstallerLog -Context $Context -Message "LAPS detectado e conta '$accountName' ausente. Criacao ignorada por configuracao." -Level Warning
            }
        }
    } else {
        $securePass = ConvertTo-SecureString $password -AsPlainText -Force
        $senhaImagemParaRegistro = $password

        if ($null -eq $usuarioImagem) {
            try {
                New-LocalUser -Name $accountName -Password $securePass -FullName $accountName -Description 'Criado por script de provisionamento' -PasswordNeverExpires -UserMayNotChangePassword:$true -ErrorAction Stop
                $imagemProntaParaRegistro = $true
                Write-InstallerLog -Context $Context -Message "Usuario '$accountName' criado com a senha gerada pelo script."
            } catch {
                Write-InstallerLog -Context $Context -Message "Erro ao criar o usuario '$accountName': detalhes sensiveis omitidos" -Level Warning
            }
        } else {
            try {
                Set-LocalUser -Name $accountName -Password $securePass -ErrorAction Stop
                $imagemProntaParaRegistro = $true
                Write-InstallerLog -Context $Context -Message "Usuario '$accountName' ja existia e nao foi detectado como gerenciado pelo LAPS. Senha atualizada pelo script."
            } catch {
                Write-InstallerLog -Context $Context -Message "Erro ao atualizar senha do usuario '$accountName': detalhes sensiveis omitidos" -Level Warning
            }
        }
    }

    $usuarioImagem = Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue
    if ($null -ne $usuarioImagem) {
        try {
            $adminGroup = Get-AdministratorsGroupName
            Add-LocalGroupMember -Group $adminGroup -Member $accountName -ErrorAction SilentlyContinue
            Write-InstallerLog -Context $Context -Message "Usuario '$accountName' garantido no grupo local '$adminGroup'."
        } catch {
            Write-InstallerLog -Context $Context -Message "Erro ao adicionar '$accountName' ao grupo Administradores: $($_.Exception.Message)" -Level Warning
        }

        if ($imagemGerenciadaPeloLaps) {
            Write-InstallerLog -Context $Context -Message "Conta '$accountName' gerenciada pelo Windows LAPS. Configuracao manual de senha nunca expira foi ignorada."
        }
        else {
            try {
                $userAds = [ADSI]"WinNT://$env:COMPUTERNAME/$accountName,user"
                $flags = $userAds.UserFlags.Value
                $userAds.Put('UserFlags', ($flags -bor 0x10000))
                $userAds.SetInfo()
                Write-InstallerLog -Context $Context -Message "Configurado 'senha nunca expira' para o usuario '$accountName'."
            }
            catch {
                Write-InstallerLog -Context $Context -Message "Erro ao configurar 'senha nunca expira' para o usuario '$accountName': $($_.Exception.Message)" -Level Warning
            }
        }
    } else {
        Write-InstallerLog -Context $Context -Message "Usuario '$accountName' nao existe apos a validacao/criacao. Etapa de grupo administrador e senha nunca expira ignorada." -Level Warning
    }

    if (-not $imagemEmSessao -and -not $imagemProntaParaRegistro) {
        $senhaImagemParaRegistro = 'NAO ALTERADA - APLICACAO LOCAL NAO CONFIRMADA'
    }

    if ([string]::IsNullOrWhiteSpace($senhaImagemParaRegistro)) { $senhaImagemParaRegistro = 'N/C' }

    if (-not $imagemEmSessao -and $imagemProntaParaRegistro) {
        try {
            $pathsUser = Write-LocalObfuscatedBackupUser -Context $Context -Pc $pc -Password $senhaImagemParaRegistro -AccountName $accountName -Stage 'GERADA'
            Write-InstallerLog -Context $Context -Message "Backup local ofuscado do usuario $accountName registrado em: $($pathsUser -join ' | ')"
        } catch {
            Write-InstallerLog -Context $Context -Message "Erro ao criar backup local ofuscado do usuario ${accountName}: detalhes sensiveis omitidos" -Level Warning
        }
    } else {
        Write-InstallerLog -Context $Context -Message "Backup de senha do usuario '$accountName' ignorado: senha preservada ou aplicacao local nao confirmada."
    }

    try {
        if (-not (Get-Module -ListAvailable -Name DellBIOSProvider)) {
            $null = Wait-Internet -Context $Context
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
                Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
                Write-InstallerLog -Context $Context -Message 'NuGet e PSGallery configurados com sucesso.'
            } catch {
                Write-InstallerLog -Context $Context -Message "Erro ao configurar NuGet/PSGallery: $($_.Exception.Message)" -Level Warning
            }

            $null = Wait-Internet -Context $Context
            Install-Module DellBIOSProvider -Force -Confirm:$false -Scope AllUsers
            Write-InstallerLog -Context $Context -Message 'Modulo DellBIOSProvider instalado.'
        } else {
            Write-InstallerLog -Context $Context -Message 'Modulo DellBIOSProvider ja esta disponivel.'
        }

        Import-Module DellBIOSProvider -Force
        Set-Item -Path DellSmbios:\Security\AdminPassword -Value $senhaBios -ErrorAction Stop
        $biosAlteradaPeloScript = $true
        $senhaBiosParaRegistro = $senhaBios
        Write-InstallerLog -Context $Context -Message 'Senha da BIOS definida com sucesso.'
    } catch {
        $biosAlteradaPeloScript = $false
        $senhaBiosParaRegistro = 'BIOS nao alterada pelo script'
        Write-InstallerLog -Context $Context -Message "Nao foi possivel definir a senha da BIOS. Pode ja existir senha configurada, nao ser Dell ou houve erro no DellBIOSProvider. O script continuara. Erro: detalhes sensiveis omitidos" -Level Warning
    }

    try {
        $pathsBios = Write-LocalObfuscatedBackupBiosIfOk -Context $Context -Pc $pc -SenhaBios $senhaBiosParaRegistro -BiosOk $biosAlteradaPeloScript -AccountName $accountName -Stage 'FINAL'
        if ($pathsBios) {
            Write-InstallerLog -Context $Context -Message "Backup local ofuscado da BIOS registrado em: $($pathsBios -join ' | ')"
        } else {
            Write-InstallerLog -Context $Context -Message "BIOS nao alterada pelo script; linha de BIOS nao foi registrada no backup local. PC: $pc"
        }
    } catch {
        Write-InstallerLog -Context $Context -Message "Erro ao registrar backup local ofuscado da BIOS: detalhes sensiveis omitidos" -Level Warning
    }

    $fields = @{}
    if (-not $imagemEmSessao -and $imagemProntaParaRegistro) {
        $fields[$imagePasswordFieldName] = $senhaImagemParaRegistro
    } else {
        Write-InstallerLog -Context $Context -Message 'Campo da senha do usuario Imagem preservado no Znuny: conta em uso ou alteracao local nao confirmada.'
    }
    if ($biosAlteradaPeloScript -and $senhaBiosParaRegistro -ne 'N/C' -and $senhaBiosParaRegistro -ne 'BIOS nao alterada pelo script') {
        $fields[$biosPasswordFieldName] = $senhaBiosParaRegistro
    } else {
        Write-InstallerLog -Context $Context -Message 'Senha da BIOS nao sera enviada ao Znuny, pois a BIOS nao foi alterada pelo script.'
    }

    Write-NetworkBackup -Context $Context -Config $znunyConfig -Pc $pc -SenhaImagemParaRegistro $senhaImagemParaRegistro -SenhaBiosParaRegistro $senhaBiosParaRegistro

    try {
        $null = Wait-Internet -Context $Context
        $registered = Send-ZnunyAssetFields -Context $Context -Config $znunyConfig -ComputerName $pc -Fields $fields
        if ($registered) { Write-InstallerLog -Context $Context -Message 'Campos aplicaveis confirmados no Znuny.' }
    } catch {
        Write-InstallerLog -Context $Context -Message "Falha ao enviar senha/status para o Znuny. O script continuara. Erro: $($_.Exception.Message)" -Level Warning
    }

}
finally {
    $senhaBios = $null
    $senhaBiosParaRegistro = $null
    $biosAlteradaPeloScript = $null
    $password = $null
    $senhaImagemParaRegistro = $null
    $securePass = $null
    [System.GC]::Collect()
}
