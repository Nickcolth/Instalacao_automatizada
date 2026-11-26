# Executar em processo separado. Nenhum acesso HTTP, conta local ou BIOS.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root '50-Integracoes\Znuny\Znuny.Api.ps1')
$context = [pscustomobject]@{ RepositoryRoot = $root }
$fakeLogin = 'mock-login-nao-real'
$fakeSecret = 'mock-secret-nao-real'
$fakeValue = 'mock-p@ss&' + [char]0x00E7 + [char]0x00E3 + 'o'
$config = [pscustomobject]@{
    Host = 'https://portal.atmis.com.br/znuny/nph-genericinterface.pl/Webservice/ativos'
    UserLogin = $fakeLogin; Password = $fakeSecret; Class = 'Computador'
}
$script:logs = @()
function Write-InstallerLog {
    param($Context, [string]$Message, [string]$Level = 'Info')
    $script:logs += $Message
}
function Assert-Test {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw "Teste falhou: $Label" }
}
function Copy-TestObject {
    param($Value)
    ConvertTo-Json -InputObject $Value -Depth 20 -Compress | ConvertFrom-Json
}
function Reset-Mock {
    param([string]$Scenario = 'normal')
    $script:scenario = $Scenario
    $script:calls = @()
    $script:patchCount = 0
    $script:contractErrors = @()
    $script:asset = [pscustomobject]@{
        ConfigItemID='101'; Name='NOTE-PILOTO'; Class='Computador';
        DeplState='Production'; InciState='Operational';
        CIXMLData=[pscustomobject]@{
            SenhaUsuarioImagem='mock-old-image'; SenhaBios='mock-old-bios';
            RAM='32GB'; SSD='512GB'; Responsavel='mock-user';
            Grupo=[pscustomobject]@{ Subcampo='preservar' }
        };
        Attachment=@([pscustomobject]@{ Filename='mock.txt'; Content='YWJj' })
    }
}
function Check-Contract {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { $script:contractErrors += $Label; throw 'Contrato simulado invalido.' }
}
# Shadow the only HTTP primitive. No fallback to the real cmdlet.
function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri,[string]$Method,[hashtable]$Headers,[int]$MaximumRedirection,[int]$TimeoutSec,[string]$ContentType,[byte[]]$Body)
    Check-Contract ($Uri.StartsWith($config.Host + '/')) 'destino'
    Check-Contract ($Headers['X-OTRS-HEADER-USERLOGIN'] -ceq $fakeLogin) 'login'
    Check-Contract ($Headers['X-OTRS-HEADER-PASSWORD'] -ceq $fakeSecret) 'senha API'
    Check-Contract ($MaximumRedirection -eq 0) 'redirecionamento'
    $path = $Uri.Substring($config.Host.Length + 1)
    $script:calls += "$Method $path"
    if ($Method -eq 'Post' -and $path -eq 'ConfigItemSearch') {
        $query = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        Check-Contract ($query.ConfigItem.Name -ceq 'NOTE-PILOTO' -and $query.ConfigItem.Class -ceq 'Computador') 'pesquisa'
        if ($script:scenario -eq 'apiError') { return [pscustomobject]@{Error=$fakeSecret} }
        if ($script:scenario -eq 'zero') { return [pscustomobject]@{ConfigItemIDs=@()} }
        if ($script:scenario -eq 'many') { return [pscustomobject]@{ConfigItemIDs=@(1..21)} }
        if ($script:scenario -eq 'duplicate') { return [pscustomobject]@{ConfigItemIDs=@('101','102')} }
        return [pscustomobject]@{ConfigItemIDs=@('101')}
    }
    if ($Method -eq 'Get' -and $path -match '^ConfigItem/(101|102)$') {
        $id = $Matches[1]
        $copy = Copy-TestObject $script:asset
        $copy.ConfigItemID = $id
        if ($script:scenario -eq 'wrongName') { $copy.Name = 'NOTE-OUTRO' }
        if ($script:scenario -eq 'wrongClass') { $copy.Class = 'Outra' }
        if ($script:scenario -eq 'missingField') { $copy.CIXMLData.PSObject.Properties.Remove('SenhaBios') }
        if ($script:scenario -eq 'missingState') { $copy.DeplState = '' }
        if ($script:patchCount -gt 0) {
            if ($script:scenario -eq 'readError') { throw $fakeSecret }
            if ($script:scenario -eq 'wrongValue') { $copy.CIXMLData.SenhaBios = 'mock-wrong' }
            if ($script:scenario -eq 'otherChanged') { $copy.CIXMLData.RAM = '16GB' }
            if ($script:scenario -eq 'stateChanged') { $copy.DeplState = 'Retired' }
            if ($script:scenario -eq 'attachmentChanged') { $copy.Attachment = @() }
        }
        return [pscustomobject]@{ConfigItem=@($copy)}
    }
    if ($Method -eq 'Patch' -and $path -eq 'ConfigItem/101') {
        $script:patchCount++
        $payload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        Check-Contract ($payload.ReplaceExistingData -eq 0 -and $payload.ConfigItemID -ceq '101') 'merge/id'
        $item = $payload.ConfigItem
        Check-Contract ($item.Name -ceq $script:asset.Name -and $item.Class -ceq $script:asset.Class) 'identidade'
        Check-Contract ($item.DeplState -ceq $script:asset.DeplState -and $item.InciState -ceq $script:asset.InciState) 'estados'
        Check-Contract ($null -eq $item.PSObject.Properties['Attachment']) 'nao reenviar anexos'
        foreach ($p in $item.CIXMLData.PSObject.Properties) {
            Check-Contract ($p.Name -cin @('SenhaUsuarioImagem','SenhaBios')) 'campos permitidos'
            $script:asset.CIXMLData.($p.Name) = $p.Value
        }
        if ($script:scenario -eq 'patchError') { throw $fakeSecret }
        if ($script:scenario -eq 'wrongId') { return [pscustomobject]@{ConfigItemID='999'} }
        return [pscustomobject]@{ConfigItemID='101'; Number='10001'}
    }
    $script:contractErrors += 'operacao inesperada'
    throw 'Operacao simulada inesperada.'
}
function Run-Case {
    param([string]$Name,[hashtable]$Fields,[bool]$Success,[int]$Patches)
    Reset-Mock $Name
    $ok = $false
    try { $ok = Send-ZnunyAssetFields -Context $context -Config $config -ComputerName 'NOTE-PILOTO' -Fields $Fields }
    catch { $script:logs += [string]$_.Exception.Message }
    Assert-Test ($ok -eq $Success) "$Name resultado"
    Assert-Test ($script:patchCount -eq $Patches) "$Name numero de PATCH"
    Assert-Test ($script:contractErrors.Count -eq 0) "$Name contrato"
    if ($Success) {
        foreach ($field in $Fields.Keys) { Assert-Test ($script:asset.CIXMLData.$field -ceq $Fields[$field]) "$Name valor" }
        Assert-Test ($script:asset.CIXMLData.RAM -ceq '32GB' -and $script:asset.Attachment.Count -eq 1) "$Name preservacao"
    }
    Write-Host "OK: $Name"
}
Run-Case normal @{SenhaBios=$fakeValue} $true 1
Run-Case normal @{SenhaUsuarioImagem='Gerenciado via LAPS';SenhaBios=$fakeValue} $true 1
Run-Case normal @{SenhaBios='mock-old-bios'} $true 0
Run-Case normal @{RAM='16GB'} $false 0
foreach ($case in @('zero','many','duplicate','wrongName','wrongClass','missingField','missingState','apiError')) {
    Run-Case $case @{SenhaBios=$fakeValue} $false 0
}
foreach ($case in @('readError','wrongValue','otherChanged','stateChanged','attachmentChanged','patchError','wrongId')) {
    Run-Case $case @{SenhaBios=$fakeValue} $false 1
}
Reset-Mock
$badConfig = Copy-TestObject $config
$badConfig.Host = 'https://portal.atmis.com.br/znuny/nph-genericinterface.pl/Webservice/outro'
$rejected = $false
try { $null = Send-ZnunyAssetFields -Context $context -Config $badConfig -ComputerName 'NOTE-PILOTO' -Fields @{SenhaBios=$fakeValue} }
catch { $rejected = $true; $script:logs += [string]$_.Exception.Message }
Assert-Test ($rejected -and $script:calls.Count -eq 0) 'URL rejeitada sem rede'
$temp = [IO.Path]::GetTempFileName()
try {
    ConvertTo-Json -InputObject $config | Set-Content -LiteralPath $temp -Encoding UTF8
    $loaded = Get-ZnunyConfig -Context $context -ConfigPath $temp
    Assert-Test ($null -ne $loaded -and $loaded.UserLogin -ceq $fakeLogin) 'leitura JSON privado simulado'
    '{invalido' | Set-Content -LiteralPath $temp -Encoding UTF8
    Assert-Test ($null -eq (Get-ZnunyConfig -Context $context -ConfigPath $temp)) 'JSON invalido'
} finally { Remove-Item -LiteralPath $temp -Force }
$allLogs = $script:logs -join "`n"
foreach ($secret in @($fakeSecret,$fakeLogin,$fakeValue,'mock-old-bios','mock-old-image')) {
    Assert-Test (-not $allLogs.Contains($secret)) 'logs sem segredos'
}
Write-Host 'TESTES SIMULADOS CONCLUIDOS COM SUCESSO.' -ForegroundColor Green
