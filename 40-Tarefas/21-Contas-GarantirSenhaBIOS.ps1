param($Context)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-RandomLower {
    $chars = 'abcdefghijkmnopqrstuvwxyz'
    return $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)]
}

function Get-RandomUpper {
    $chars = 'ABCDEFGHIJKLMNPQRSTUVWXYZ'
    return $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)]
}

function Get-RandomDigit {
    return [string](Get-Random -Minimum 0 -Maximum 10)
}

function Get-RandomSpecial {
    $chars = '!@#$%&*'
    return $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)]
}

function New-BiosPassword {
    $parts = @(
        (Get-RandomLower),
        (Get-RandomUpper),
        (Get-RandomDigit),
        (Get-RandomLower),
        (Get-RandomDigit),
        (Get-RandomUpper),
        (Get-RandomLower),
        (Get-RandomDigit),
        (Get-RandomSpecial),
        (Get-RandomLower),
        (Get-RandomUpper),
        (Get-RandomDigit)
    )

    return ($parts -join '')
}

function ConvertTo-BiosBool {
    param($Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim()

    if ($text -match '^(?i:true|1|yes|enabled)$') {
        return $true
    }

    return $false
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
                    'NuGet nao precisou ser instalado ou falhou ao ' +
                    "preparar: $($_.Exception.Message)"
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

function Get-DellProviderPasswordState {
    $adminSet = $null
    $systemSet = $null

    try {
        $adminItem = Get-Item `
            -Path 'DellSmbios:\Security\IsAdminPasswordSet' `
            -ErrorAction Stop

        if ($adminItem.PSObject.Properties['CurrentValue']) {
            $adminSet = ConvertTo-BiosBool $adminItem.CurrentValue
        }
        elseif ($adminItem.PSObject.Properties['Value']) {
            $adminSet = ConvertTo-BiosBool $adminItem.Value
        }
    }
    catch {}

    try {
        $systemItem = Get-Item `
            -Path 'DellSmbios:\Security\IsSystemPasswordSet' `
            -ErrorAction Stop

        if ($systemItem.PSObject.Properties['CurrentValue']) {
            $systemSet = ConvertTo-BiosBool $systemItem.CurrentValue
        }
        elseif ($systemItem.PSObject.Properties['Value']) {
            $systemSet = ConvertTo-BiosBool $systemItem.Value
        }
    }
    catch {}

    return [pscustomobject]@{
        AdminSet = $adminSet
        SystemSet = $systemSet
    }
}

function Get-DellCimPasswordState {
    try {
        $passwords = @(
            Get-CimInstance `
                -Namespace 'root\dcim\sysman' `
                -ClassName 'DCIM_BIOSPassword' `
                -ErrorAction Stop
        )

        $admin = $passwords |
            Where-Object {
                [string]$_.AttributeName -ieq 'AdminPwd'
            } |
            Select-Object -First 1

        $system = $passwords |
            Where-Object {
                [string]$_.AttributeName -ieq 'SystemPwd'
            } |
            Select-Object -First 1

        return [pscustomobject]@{
            Available = $true
            AdminSet = if ($null -ne $admin) {
                ConvertTo-BiosBool $admin.IsSet
            }
            else {
                $null
            }
            SystemSet = if ($null -ne $system) {
                ConvertTo-BiosBool $system.IsSet
            }
            else {
                $null
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            AdminSet = $null
            SystemSet = $null
        }
    }
}

function Test-BiosAdminPasswordSet {
    $providerState = Get-DellProviderPasswordState

    if ($null -ne $providerState.AdminSet) {
        return [bool]$providerState.AdminSet
    }

    $cimState = Get-DellCimPasswordState

    if ($cimState.Available -and $null -ne $cimState.AdminSet) {
        return [bool]$cimState.AdminSet
    }

    return $null
}

function Save-LocalBiosBackup {
    param(
        $Context,
        [string]$ComputerName,
        [string]$Password
    )

    $datahora = Get-Date -Format 'yyyyMMddHHmmss'
    $randomTail = Get-Random -Minimum 10000 -Maximum 99999
    $line = "biosguard${datahora}FINAL${Password}biosok${randomTail}"

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
                -Message (
                    'Pasta de backup de senha da BIOS nao esta ' +
                    "acessivel: $logFolder"
                ) `
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

    if ($null -eq $Config) {
        return
    }

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
                'name',
                'displayName',
                'text',
                'assetName',
                'number'
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
        -Message (
            "Garantia de senha da BIOS ignorada. Fabricante: $manufacturer"
        )

    return
}

Write-InstallerLog `
    -Context $Context `
    -Message (
        "Verificando senha de administrador da BIOS Dell. " +
        "Fabricante: $manufacturer"
    )

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
            'DellBIOSProvider nao ficou disponivel. O script tentara ' +
            "o metodo CIM da Dell. Erro: $providerError"
        ) `
        -Level Warning
}

if ($providerReady) {
    $state = Get-DellProviderPasswordState

    if ($state.AdminSet -eq $true) {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Senha de administrador da BIOS ja esta configurada. ' +
                'Nenhuma alteracao sera feita.'
            ) `
            -Level Success

        return
    }

    if ($state.SystemSet -eq $true) {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'A BIOS possui senha de sistema. A Dell nao permite ' +
                'definir AdminPassword nessa condicao sem tratar a senha ' +
                'existente. A BIOS foi preservada.'
            ) `
            -Level Warning

        return
    }
}
else {
    $cimStateBefore = Get-DellCimPasswordState

    if (
        $cimStateBefore.Available -and
        $cimStateBefore.AdminSet -eq $true
    ) {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Senha de administrador da BIOS ja esta configurada ' +
                'segundo o namespace CIM da Dell.'
            ) `
            -Level Success

        return
    }

    if (
        $cimStateBefore.Available -and
        $cimStateBefore.SystemSet -eq $true
    ) {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Senha de sistema da BIOS detectada pelo CIM. A senha de ' +
                'administrador nao sera criada para evitar conflito.'
            ) `
            -Level Warning

        return
    }
}

$newPassword = New-BiosPassword
$biosSet = $false
$methodUsed = $null
$providerSetError = $null

if ($providerReady) {
    try {
        Write-InstallerLog `
            -Context $Context `
            -Message 'Tentando definir a senha da BIOS pelo DellBIOSProvider.'

        Set-Item `
            -Path 'DellSmbios:\Security\AdminPassword' `
            -Value $newPassword `
            -ErrorAction Stop

        Start-Sleep -Seconds 2

        $verified = Test-BiosAdminPasswordSet

        if ($verified -eq $true) {
            $biosSet = $true
            $methodUsed = 'DellBIOSProvider'
        }
        else {
            throw (
                'O comando terminou sem erro, mas IsAdminPasswordSet ' +
                'nao confirmou a senha.'
            )
        }
    }
    catch {
        $providerSetError = $_.Exception.Message

        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Tentativa pelo DellBIOSProvider nao foi confirmada. ' +
                "Sera usado o fallback CIM. Erro: $providerSetError"
            ) `
            -Level Warning
    }
}

if (-not $biosSet) {
    try {
        Write-InstallerLog `
            -Context $Context `
            -Message (
                'Tentando definir a senha da BIOS pelo ' +
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
            throw "SetBIOSAttributes retornou codigo $returnValue."
        }

        Start-Sleep -Seconds 2
        $cimStateAfter = Get-DellCimPasswordState
        $providerVerifiedAfter = $null

        if ($providerReady) {
            $providerVerifiedAfter = Test-BiosAdminPasswordSet
        }

        if (
            ($cimStateAfter.Available -and $cimStateAfter.AdminSet -eq $true) -or
            $providerVerifiedAfter -eq $true
        ) {
            $biosSet = $true
            $methodUsed = 'DCIM_BIOSService'
        }
        else {
            # ReturnValue 0 significa que a Dell aceitou a alteracao. Em alguns
            # modelos a consulta do estado nao atualiza imediatamente.
            $biosSet = $true
            $methodUsed = 'DCIM_BIOSService-retorno-0'

            Write-InstallerLog `
                -Context $Context `
                -Message (
                    'A Dell retornou sucesso ao configurar a senha, mas a ' +
                    'consulta de confirmacao ainda nao refletiu a mudanca.'
                ) `
                -Level Warning
        }
    }
    catch {
        $details = $_.Exception.Message

        if (-not [string]::IsNullOrWhiteSpace($providerSetError)) {
            $details = (
                "DellBIOSProvider: $providerSetError | CIM: $details"
            )
        }

        throw (
            'Nao foi possivel garantir a senha de administrador da BIOS ' +
            "Dell. $details"
        )
    }
}

if (-not $biosSet) {
    throw 'A senha da BIOS nao foi confirmada por nenhum metodo.'
}

Save-BiosPassword `
    -Context $Context `
    -Password $newPassword

Write-InstallerLog `
    -Context $Context `
    -Message (
        'Senha de administrador da BIOS criada e registrada com sucesso. ' +
        "Metodo: $methodUsed"
    ) `
    -Level Success
