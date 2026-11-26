param($Context)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $Context.RepositoryRoot '50-Integracoes\Znuny\Znuny.Api.ps1')

function New-BiosPassword {
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $upper = 'ABCDEFGHIJKLMNPQRSTUVWXYZ'
    $digits = '23456789'
    $special = '!@#$%&*'
    $all = $lower + $upper + $digits

    $chars = @(
        $lower[(Get-Random -Minimum 0 -Maximum $lower.Length)],
        $upper[(Get-Random -Minimum 0 -Maximum $upper.Length)],
        $digits[(Get-Random -Minimum 0 -Maximum $digits.Length)],
        $special[(Get-Random -Minimum 0 -Maximum $special.Length)]
    )

    while ($chars.Count -lt 12) {
        $chars += $all[(Get-Random -Minimum 0 -Maximum $all.Length)]
    }

    return (-join ($chars | Sort-Object { Get-Random }))
}

function ConvertTo-BiosBool {
    param($Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim()
    return ($text -match '^(?i:true|1|yes|enabled)$')
}

function Ensure-DellBiosProvider {
    param($Context)

    if (-not (Get-Module -ListAvailable -Name DellBIOSProvider)) {
        Write-InstallerLog `
            -Context $Context `
            -Message 'DellBIOSProvider nao encontrado. Instalando modulo.'

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        catch {}

        try {
            Install-PackageProvider `
                -Name NuGet `
                -MinimumVersion 2.8.5.201 `
                -Force `
                -Scope AllUsers `
                -ErrorAction Stop |
                Out-Null
        }
        catch {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'NuGet nao precisou ser instalado ou falhou ao preparar: ' +
                    $_.Exception.Message
                ) `
                -Level Warning
        }

        try {
            Set-PSRepository `
                -Name PSGallery `
                -InstallationPolicy Trusted `
                -ErrorAction SilentlyContinue
        }
        catch {}

        Install-Module `
            DellBIOSProvider `
            -Force `
            -Confirm:$false `
            -Scope AllUsers `
            -ErrorAction Stop
    }

    Import-Module DellBIOSProvider -Force -ErrorAction Stop

    if (-not (Get-PSDrive -Name DellSmbios -ErrorAction SilentlyContinue)) {
        throw 'O drive DellSmbios nao foi criado pelo DellBIOSProvider.'
    }
}

function Get-BiosPasswordState {
    $adminSet = $null
    $systemSet = $null
    $source = 'Nao consultavel'

    try {
        if (Get-PSDrive -Name DellSmbios -ErrorAction SilentlyContinue) {
            try {
                $adminItem = Get-Item `
                    'DellSmbios:\Security\IsAdminPasswordSet' `
                    -ErrorAction Stop

                $value = $null
                if ($adminItem.PSObject.Properties['CurrentValue']) {
                    $value = $adminItem.CurrentValue
                }
                elseif ($adminItem.PSObject.Properties['Value']) {
                    $value = $adminItem.Value
                }

                if ($null -ne $value) {
                    $adminSet = ConvertTo-BiosBool $value
                    $source = 'DellBIOSProvider'
                }
            }
            catch {}

            try {
                $systemItem = Get-Item `
                    'DellSmbios:\Security\IsSystemPasswordSet' `
                    -ErrorAction Stop

                $value = $null
                if ($systemItem.PSObject.Properties['CurrentValue']) {
                    $value = $systemItem.CurrentValue
                }
                elseif ($systemItem.PSObject.Properties['Value']) {
                    $value = $systemItem.Value
                }

                if ($null -ne $value) {
                    $systemSet = ConvertTo-BiosBool $value
                }
            }
            catch {}
        }
    }
    catch {}

    if ($null -eq $adminSet -or $null -eq $systemSet) {
        try {
            $passwords = @(
                Get-CimInstance `
                    -Namespace 'root\dcim\sysman' `
                    -ClassName 'DCIM_BIOSPassword' `
                    -ErrorAction Stop
            )

            if ($null -eq $adminSet) {
                $admin = $passwords |
                    Where-Object {
                        [string]$_.AttributeName -ieq 'AdminPwd'
                    } |
                    Select-Object -First 1

                if ($null -ne $admin) {
                    $adminSet = ConvertTo-BiosBool $admin.IsSet
                    $source = 'CIM Dell'
                }
            }

            if ($null -eq $systemSet) {
                $system = $passwords |
                    Where-Object {
                        [string]$_.AttributeName -ieq 'SystemPwd'
                    } |
                    Select-Object -First 1

                if ($null -ne $system) {
                    $systemSet = ConvertTo-BiosBool $system.IsSet
                }
            }
        }
        catch {}
    }

    return [pscustomobject]@{
        AdminSet = $adminSet
        SystemSet = $systemSet
        Source = $source
    }
}

function Save-LocalBiosBackup {
    param(
        $Context,
        [string]$ComputerName,
        [string]$Password
    )

    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $randomTail = Get-Random -Minimum 10000 -Maximum 99999
    $line = "biosguard${stamp}FINAL${Password}biosok${randomTail}"

    if ($line.Length -lt 130) {
        $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        $builder = New-Object System.Text.StringBuilder

        while (($line.Length + $builder.Length) -lt 130) {
            $null = $builder.Append(
                $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)]
            )
        }

        $line += $builder.ToString()
    }

    foreach ($folder in @(
        'C:\ProgramData\IMG',
        'C:\Program Files\IMG'
    )) {
        try {
            New-Item `
                -Path $folder `
                -ItemType Directory `
                -Force `
                -ErrorAction Stop |
                Out-Null

            Add-Content `
                -Path (Join-Path $folder "$ComputerName.txt") `
                -Value $line `
                -Encoding UTF8 `
                -ErrorAction Stop
        }
        catch {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    "Falha ao registrar backup local da BIOS em '$folder': " +
                    'detalhes sensiveis omitidos'
                ) `
                -Level Warning
        }
    }
}

function Save-NetworkBiosBackup {
    param(
        $Context,
        $Config,
        [string]$ComputerName,
        [string]$Password
    )

    $logFolder = '\\fileserver\SDK\Softwares\Instalacao_automatizada\logsenha'

    if (
        $null -ne $Config -and
        $Config.PSObject.Properties['networkBackupPath'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$Config.networkBackupPath
        )
    ) {
        $logFolder = [string]$Config.networkBackupPath
    }

    try {
        if (-not (Test-Path -Path $logFolder)) {
            Write-InstallerLog `
                -Context $Context `
                -Message "Pasta de backup da BIOS nao esta acessivel: $logFolder" `
                -Level Warning
            return
        }

        $logFile = Join-Path $logFolder "$ComputerName.txt"
        $content = @"
==============================
Data e hora: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
Computador: $ComputerName
Senha Admin da BIOS: $Password
Origem: garantia-pos-validacao
==============================
"@

        $content |
            Out-File `
                -FilePath $logFile `
                -Encoding UTF8 `
                -Append `
                -ErrorAction Stop

        Write-InstallerLog `
            -Context $Context `
            -Message "Backup da nova senha da BIOS salvo em $logFile"
    }
    catch {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Falha ao gravar backup de rede da senha da BIOS: ' +
                'detalhes sensiveis omitidos'
            ) `
            -Level Warning
    }
}

function Send-BiosPasswordToZnuny {
    param($Context, $Config, [string]$ComputerName, [string]$Password)

    try {
        return (Send-ZnunyAssetFields -Context $Context -Config $Config -ComputerName $ComputerName -Fields @{SenhaBios=$Password})
    }
    catch {
        Write-InstallerLog -Context $Context -Message ('Falha ao registrar a nova senha da BIOS no Znuny: ' + $_.Exception.Message) -Level Warning
        return $false
    }
}

function Save-BiosPassword {
    param($Context, [string]$Password)

    $computerName = [string]$env:COMPUTERNAME
    $config = Get-ZnunyConfig -Context $Context
    Save-LocalBiosBackup -Context $Context -ComputerName $computerName -Password $Password
    Save-NetworkBiosBackup -Context $Context -Config $config -ComputerName $computerName -Password $Password
    return (Send-BiosPasswordToZnuny -Context $Context -Config $config -ComputerName $computerName -Password $Password)
}

$computerSystem = Get-CimInstance `
    -ClassName Win32_ComputerSystem `
    -ErrorAction Stop

$manufacturer = [string]$computerSystem.Manufacturer

if ($manufacturer -notmatch '(?i)dell|alienware') {
    Write-InstallerLog `
        -Context $Context `
        -Message "Garantia de senha da BIOS ignorada. Fabricante: $manufacturer"
    return
}

Write-InstallerLog `
    -Context $Context `
    -Message "Verificando senha de administrador da BIOS. Fabricante: $manufacturer"

$providerReady = $false
$providerError = $null

try {
    Ensure-DellBiosProvider -Context $Context
    $providerReady = $true
}
catch {
    $providerError = $_.Exception.Message
    Write-InstallerLog `
        -Context $Context `
        -Message (
            'DellBIOSProvider nao ficou disponivel. ' +
            "O metodo alternativo CIM sera tentado se necessario. Erro: $providerError"
        ) `
        -Level Warning
}

$stateBefore = Get-BiosPasswordState

if ($stateBefore.AdminSet -eq $true) {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            'BIOS ja possui senha de administrador. ' +
            'Nenhuma senha foi criada ou alterada pelo script. ' +
            "Deteccao: $($stateBefore.Source)."
        ) `
        -Level Success
    return
}

if ($stateBefore.SystemSet -eq $true) {
    Write-InstallerLog `
        -Context $Context `
        -Message (
            'Senha de sistema detectada, mas nenhuma senha Admin foi ' +
            'confirmada. O script tentara criar AdminPassword normalmente.'
        ) `
        -Level Warning
}

$newPassword = New-BiosPassword
$biosSet = $false
$methodUsed = $null
$directError = $null

# Metodo principal: exatamente o mesmo usado pelo script original que ja era
# conhecido por funcionar nos Dell e Alienware.
if ($providerReady) {
    try {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'BIOS sem senha detectada. Tentando o metodo principal ' +
                'pelo DellBIOSProvider.'
            )

        Set-Item `
            -Path 'DellSmbios:\Security\AdminPassword' `
            -Value $newPassword `
            -ErrorAction Stop

        $biosSet = $true
        $methodUsed = 'DellBIOSProvider-SetItem'

        Write-InstallerLog `
            -Context $Context `
            -Message (
                'DellBIOSProvider aceitou a nova senha da BIOS. ' +
                'Metodo original executado com sucesso.'
            ) `
            -Level Success
    }
    catch {
        $directError = 'Falha no DellBIOSProvider; detalhes sensiveis omitidos.'

        $stateAfterDirectFailure = Get-BiosPasswordState

        if ($stateAfterDirectFailure.AdminSet -eq $true) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'O metodo principal nao alterou a BIOS porque uma senha ' +
                    'de administrador ja esta configurada. Isso nao e uma falha.'
                ) `
                -Level Success
            return
        }

        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Metodo principal DellBIOSProvider falhou. ' +
                "Tentando metodo alternativo CIM. Erro: $directError"
            ) `
            -Level Warning
    }
}

# Metodo alternativo: interface CIM oficial da Dell.
if (-not $biosSet) {
    try {
        $stateBeforeFallback = Get-BiosPasswordState

        if ($stateBeforeFallback.AdminSet -eq $true) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'BIOS ja possui senha de administrador. ' +
                    'Metodo alternativo nao sera executado.'
                ) `
                -Level Success
            return
        }

        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Executando metodo alternativo para senha da BIOS: ' +
                'DCIM_BIOSService.SetBIOSAttributes.'
            )

        $biosService = Get-CimInstance `
            -Namespace 'root\dcim\sysman' `
            -ClassName 'DCIM_BIOSService' `
            -ErrorAction Stop |
            Select-Object -First 1

        if ($null -eq $biosService) {
            throw 'DCIM_BIOSService nao foi encontrado.'
        }

        $result = $biosService |
            Invoke-CimMethod `
                -MethodName 'SetBIOSAttributes' `
                -Arguments @{
                    AttributeName = @('AdminPwd')
                    AttributeValue = @($newPassword)
                } `
                -ErrorAction Stop

        $returnValue = 0

        if (
            $null -ne $result -and
            $result.PSObject.Properties['ReturnValue']
        ) {
            $returnValue = [int]$result.ReturnValue
        }

        if ($returnValue -ne 0) {
            $stateAfterFallbackFailure = Get-BiosPasswordState

            if ($stateAfterFallbackFailure.AdminSet -eq $true) {
                Write-InstallerLog `
                    -Context $Context `
                    -Message (
                        'Metodo alternativo nao alterou a BIOS porque uma ' +
                        'senha de administrador ja esta configurada. ' +
                        'Isso nao e uma falha.'
                    ) `
                    -Level Success
                return
            }

            throw "SetBIOSAttributes retornou codigo $returnValue."
        }

        $biosSet = $true
        $methodUsed = 'DCIM_BIOSService'

        Write-InstallerLog `
            -Context $Context `
            -Message 'Metodo alternativo CIM aceitou a nova senha da BIOS.' `
            -Level Success
    }
    catch {
        $fallbackError = 'Falha no metodo CIM; detalhes sensiveis omitidos.'
        $finalState = Get-BiosPasswordState

        if ($finalState.AdminSet -eq $true) {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'BIOS ja possui senha de administrador. ' +
                    'Nenhuma alteracao adicional foi feita e isso nao e uma falha.'
                ) `
                -Level Success
            return
        }

        $details = "CIM: $fallbackError"
        if (-not [string]::IsNullOrWhiteSpace($directError)) {
            $details = "DellBIOSProvider: $directError | $details"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($providerError)) {
            $details = "DellBIOSProvider: $providerError | $details"
        }

        throw (
            'Nao foi possivel criar a senha da BIOS por nenhum dos metodos. ' +
            $details
        )
    }
}

if (-not $biosSet) {
    throw 'A senha da BIOS nao foi criada por nenhum metodo.'
}

$znunyRecorded = Save-BiosPassword -Context $Context -Password $newPassword

if ($znunyRecorded) {
    Write-InstallerLog -Context $Context -Message "Senha de administrador da BIOS criada e confirmada no Znuny. Metodo usado: $methodUsed" -Level Success
}
else {
    Write-InstallerLog -Context $Context -Message "Senha da BIOS criada. Registro no Znuny pendente; confira os backups existentes. Metodo usado: $methodUsed" -Level Warning
}
