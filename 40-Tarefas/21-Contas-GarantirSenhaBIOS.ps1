param($Context)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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
                    $_.Exception.Message
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
                $_.Exception.Message
            ) `
            -Level Warning
    }
}

function Send-BiosPasswordToTopdesk {
    param(
        $Context,
        $Config,
        [string]$ComputerName,
        [string]$Password
    )

    if ($null -eq $Config) { return }

    foreach ($required in @('baseUrl','username','password')) {
        if (
            -not $Config.PSObject.Properties[$required] -or
            [string]::IsNullOrWhiteSpace([string]$Config.$required)
        ) {
            return
        }
    }

    $fieldName = 'senha-bios'

    if (
        $Config.PSObject.Properties['biosPasswordFieldName'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$Config.biosPasswordFieldName
        )
    ) {
        $fieldName = [string]$Config.biosPasswordFieldName
    }

    try {
        $baseUrl = ([string]$Config.baseUrl).TrimEnd('/')
        $pair = '{0}:{1}' -f `
            [string]$Config.username,
            [string]$Config.password

        $basic = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes($pair)
        )

        $headers = @{
            Authorization = "Basic $basic"
            Accept = 'application/json'
            'Content-Type' = 'application/json'
        }

        $encodedName = [Uri]::EscapeDataString($ComputerName)
        $result = Invoke-RestMethod `
            -Uri "$baseUrl/tas/api/assetmgmt/assets?nameFragment=$encodedName" `
            -Headers $headers `
            -Method Get `
            -ErrorAction Stop

        $assets = @()

        if ($null -ne $result.PSObject.Properties['dataSet']) {
            $assets = @($result.dataSet)
        }
        elseif ($null -ne $result.PSObject.Properties['results']) {
            $assets = @($result.results)
        }
        else {
            $assets = @($result)
        }

        $asset = $null

        foreach ($candidate in $assets) {
            $candidateName = $null

            foreach ($nameProperty in @(
                'name','displayName','text','assetName','number'
            )) {
                if (
                    $candidate.PSObject.Properties[$nameProperty] -and
                    $null -ne $candidate.$nameProperty
                ) {
                    $candidateName = [string]$candidate.$nameProperty
                    break
                }
            }

            if ($candidateName -ieq $ComputerName) {
                $asset = $candidate
                break
            }
        }

        if ($null -eq $asset) {
            $asset = $assets | Select-Object -First 1
        }

        if ($null -eq $asset) {
            throw "Ativo nao encontrado no TOPdesk: $ComputerName"
        }

        $assetId = $null

        foreach ($idProperty in @('id','unid','assetId')) {
            if (
                $asset.PSObject.Properties[$idProperty] -and
                $null -ne $asset.$idProperty
            ) {
                $assetId = [string]$asset.$idProperty
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($assetId)) {
            throw 'Ativo encontrado sem identificador utilizavel.'
        }

        $body = @{
            $fieldName = $Password
        } | ConvertTo-Json -Depth 4

        Invoke-RestMethod `
            -Uri "$baseUrl/tas/api/assetmgmt/assets/$assetId" `
            -Headers $headers `
            -Method Post `
            -Body $body `
            -ErrorAction Stop |
            Out-Null

        Write-InstallerLog `
            -Context $Context `
            -Message 'Nova senha da BIOS registrada no TOPdesk.' `
            -Level Success
    }
    catch {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Falha ao registrar a nova senha da BIOS no TOPdesk: ' +
                $_.Exception.Message
            ) `
            -Level Warning
    }
}

function Save-BiosPassword {
    param(
        $Context,
        [string]$Password
    )

    $computerName = [string]$env:COMPUTERNAME
    $config = $null
    $configPath = Join-Path `
        $Context.RepositoryRoot `
        '60-Segredos\topdesk-config.json'

    if (Test-Path $configPath) {
        try {
            $config = Get-Content `
                -Path $configPath `
                -Raw `
                -Encoding UTF8 `
                -ErrorAction Stop |
                ConvertFrom-Json
        }
        catch {
            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'Nao foi possivel ler a configuracao do TOPdesk para ' +
                    "registrar a BIOS: $($_.Exception.Message)"
                ) `
                -Level Warning
        }
    }

    Save-LocalBiosBackup `
        -Context $Context `
        -ComputerName $computerName `
        -Password $Password

    Save-NetworkBiosBackup `
        -Context $Context `
        -Config $config `
        -ComputerName $computerName `
        -Password $Password

    Send-BiosPasswordToTopdesk `
        -Context $Context `
        -Config $config `
        -ComputerName $computerName `
        -Password $Password
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
            'BIOS possui senha de sistema. Nenhuma alteracao foi feita ' +
            'para evitar conflito com a senha existente.'
        ) `
        -Level Warning
    return
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
        $directError = $_.Exception.Message

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
        $fallbackError = $_.Exception.Message
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

Save-BiosPassword `
    -Context $Context `
    -Password $newPassword

Write-InstallerLog `
    -Context $Context `
    -Message (
        'Senha de administrador da BIOS criada e registrada com sucesso. ' +
        "Metodo usado: $methodUsed"
    ) `
    -Level Success
