# Funcoes de API. Este arquivo nao executa alteracoes ao ser carregado.
function Get-ZnunyProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-ZnunyConfig {
    param($Context, [string]$ConfigPath)

    # GitHub guarda apenas o exemplo. Sem senha embutida ou prompt de API.
    $paths = @()
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $paths = @($ConfigPath)
    }
    else {
        $paths = @(
            (Join-Path $Context.RepositoryRoot '60-Segredos\Znuny-Producao.config.json'),
            '\\fileserver\SDK\Softwares\Instalacao_automatizada\Znuny\Znuny-Producao.config.json'
        )
    }
    foreach ($path in $paths) {
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)) { continue }
            $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            foreach ($required in @('Host', 'UserLogin', 'Password')) {
                if ([string]::IsNullOrWhiteSpace([string](Get-ZnunyProperty $config $required))) {
                    throw 'Configuracao incompleta.'
                }
            }
            $baseUrl = ([string]$config.Host).Trim().TrimEnd('/')
            $uri = $null
            if (-not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$uri)) { throw 'URL invalida.' }
            if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'portal.atmis.com.br' -or
                -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
                $uri.AbsolutePath -cne '/znuny/nph-genericinterface.pl/Webservice/ativos') {
                throw 'URL fora da API de producao.'
            }
            return $config
        }
        catch {
            # Erros de parsing podem incluir conteudo do JSON; nao os imprimir.
            Write-InstallerLog -Context $Context -Message 'Configuracao do Znuny inacessivel ou invalida. Registro ignorado; credenciais nao serao exibidas.' -Level Warning
            return $null
        }
    }
    Write-InstallerLog -Context $Context -Message 'JSON do Znuny indisponivel no fileserver e na copia local de segredos. Registro no CMDB sera ignorado.' -Level Warning
    return $null
}

function Invoke-ZnunyRequest {
    param(
        [string]$BaseUrl, [hashtable]$Headers,
        [ValidateSet('Get','Post','Patch')][string]$Method,
        [string]$Path, $Data, [string]$Stage
    )
    if (($Method -eq 'Post' -and $Path -cne 'ConfigItemSearch') -or
        ($Method -in @('Get','Patch') -and $Path -notmatch '^ConfigItem/\d+$')) {
        throw 'Operacao fora da integracao de senhas.'
    }
    $request = @{
        Uri = "$BaseUrl/$Path"; Method = $Method; Headers = $Headers
        MaximumRedirection = 0; TimeoutSec = 30; ErrorAction = 'Stop'
        Verbose = $false; Debug = $false
    }
    if ($null -ne $Data) {
        $request.ContentType = 'application/json; charset=utf-8'
        $json = ConvertTo-Json -InputObject $Data -Depth 40 -Compress
        $request.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }
    try {
        $result = Invoke-RestMethod @request
        if ($null -eq $result -or $result -is [string] -or
            $null -ne (Get-ZnunyProperty $result 'Error')) { throw 'Resposta invalida.' }
        return $result
    }
    catch {
        # Nao propaga ErrorDetails, payload ou InnerException com segredos.
        $response = Get-ZnunyProperty $_.Exception 'Response'
        $status = Get-ZnunyProperty $response 'StatusCode'
        if ($null -ne $status) {
            throw "Znuny: falha na etapa '$Stage' (HTTP $([int]$status)); detalhes sensiveis omitidos."
        }
        throw "Znuny: falha na etapa '$Stage'; detalhes sensiveis omitidos."
    }
    finally {
        if ($request.ContainsKey('Body')) {
            [Array]::Clear($request.Body, 0, $request.Body.Length)
            $request.Remove('Body')
        }
        $json = $null
        $Data = $null
    }
}

function Send-ZnunyAssetFields {
    param($Context, $Config, [string]$ComputerName, [hashtable]$Fields)

    if ($null -eq $Config -or $null -eq $Fields -or $Fields.Count -eq 0) { return $false }
    $headers = @{}
    $stage = 'validacao/pesquisa'
    try {
        if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw 'Nome do computador ausente. Nenhuma alteracao enviada.' }
        foreach ($field in $Fields.Keys) {
            if ($field -cnotin @('SenhaUsuarioImagem','SenhaBios') -or
                $Fields[$field] -isnot [string] -or [string]::IsNullOrEmpty($Fields[$field])) {
                throw 'Campo ou valor fora da integracao de senhas. Nenhuma alteracao enviada.'
            }
        }
        $baseUrl = ([string](Get-ZnunyProperty $Config 'Host')).Trim().TrimEnd('/')
        $target = $null
        if (-not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$target) -or
            $target.Scheme -ne 'https' -or $target.Host -ne 'portal.atmis.com.br' -or
            -not $target.IsDefaultPort -or $target.UserInfo -or $target.Query -or $target.Fragment -or
            $target.AbsolutePath -cne '/znuny/nph-genericinterface.pl/Webservice/ativos') {
            throw 'Destino fora da API HTTPS de producao. Nenhuma alteracao enviada.'
        }
        $login = [string](Get-ZnunyProperty $Config 'UserLogin')
        $apiPassword = [string](Get-ZnunyProperty $Config 'Password')
        if ([string]::IsNullOrWhiteSpace($login) -or [string]::IsNullOrEmpty($apiPassword)) {
            throw 'Credenciais ausentes no JSON. Nenhuma alteracao enviada.'
        }
        $className = [string](Get-ZnunyProperty $Config 'Class')
        if ([string]::IsNullOrWhiteSpace($className)) { $className = 'Computador' }
        $headers = @{
            'X-OTRS-HEADER-USERLOGIN' = $login
            'X-OTRS-HEADER-PASSWORD' = $apiPassword
            Accept = 'application/json'
        }
        $search = Invoke-ZnunyRequest -BaseUrl $baseUrl -Headers $headers -Method Post -Path 'ConfigItemSearch' -Data @{ConfigItem=@{Class=$className;Name=$ComputerName}} -Stage 'pesquisa'
        $ids = @((Get-ZnunyProperty $search 'ConfigItemIDs') | Where-Object { $null -ne $_ -and "$_" -ne '' } | Select-Object -Unique)
        if ($ids.Count -eq 0 -or $ids.Count -gt 20) { throw 'Pesquisa sem resultado ou ampla demais. Nenhuma alteracao enviada.' }
        $candidates = @(
            foreach ($id in $ids) {
                if ("$id" -notmatch '^\d+$') { throw 'Identificador invalido. Nenhuma alteracao enviada.' }
                $response = Invoke-ZnunyRequest -BaseUrl $baseUrl -Headers $headers -Method Get -Path "ConfigItem/$id" -Stage 'leitura'
                $items = @(Get-ZnunyProperty $response 'ConfigItem')
                if ($items.Count -eq 0 -or $null -eq $items[0]) { throw 'Detalhes ausentes. Nenhuma alteracao enviada.' }
                foreach ($item in $items) {
                    if ([string](Get-ZnunyProperty $item 'ConfigItemID') -cne "$id") {
                        throw 'Identificador divergente. Nenhuma alteracao enviada.'
                    }
                    if ([string](Get-ZnunyProperty $item 'Name') -ieq $ComputerName -and
                        [string](Get-ZnunyProperty $item 'Class') -ieq $className) { $item }
                }
            }
        )
        if ($candidates.Count -ne 1) { throw 'Nao ha um unico ativo com nome e classe exatos. Nenhuma alteracao enviada.' }
        $asset = $candidates[0]
        $assetId = [string]$asset.ConfigItemID
        $before = Get-ZnunyProperty $asset 'CIXMLData'
        if ($null -eq $before -or $before -is [string] -or $before -is [Array]) { throw 'CIXMLData invalido. Nenhuma alteracao enviada.' }
        $changed = @{}
        foreach ($field in $Fields.Keys) {
            if ($null -eq $before.PSObject.Properties[$field]) { throw 'Campo de senha ausente. Nenhuma alteracao enviada.' }
            if (-not [string]::Equals([string]$before.$field, $Fields[$field], [StringComparison]::Ordinal)) {
                $changed[$field] = $Fields[$field]
            }
        }
        if ($changed.Count -eq 0) {
            Write-InstallerLog -Context $Context -Message "Znuny: campos ja conferem para $ComputerName. Nenhuma gravacao necessaria."
            return $true
        }
        # O contrato exige os estados. Repete os atuais, sem escolher novos.
        $deplState = [string](Get-ZnunyProperty $asset 'DeplState')
        $inciState = [string](Get-ZnunyProperty $asset 'InciState')
        if ([string]::IsNullOrWhiteSpace($deplState) -or [string]::IsNullOrWhiteSpace($inciState)) {
            throw 'Estados atuais indisponiveis. Nenhuma alteracao enviada.'
        }
        # Somente dois campos XML podem mudar. O restante e mesclado no servidor.
        $payload = @{
            ReplaceExistingData = 0; ConfigItemID = $assetId
            ConfigItem = @{
                Class=[string]$asset.Class; Name=[string]$asset.Name
                DeplState=$deplState; InciState=$inciState; CIXMLData=$changed
            }
        }
        $stage = 'gravacao ou confirmacao (pode ter sido gravado)'
        $updated = Invoke-ZnunyRequest -BaseUrl $baseUrl -Headers $headers -Method Patch -Path "ConfigItem/$assetId" -Data $payload -Stage 'gravacao'
        if ([string](Get-ZnunyProperty $updated 'ConfigItemID') -cne $assetId) {
            throw 'Gravacao enviada sem identificador confirmado. Confira o CMDB; nao repetir automaticamente.'
        }
        $confirmation = Invoke-ZnunyRequest -BaseUrl $baseUrl -Headers $headers -Method Get -Path "ConfigItem/$assetId" -Stage 'confirmacao'
        $confirmed = @(Get-ZnunyProperty $confirmation 'ConfigItem')
        if ($confirmed.Count -ne 1 -or
            [string](Get-ZnunyProperty $confirmed[0] 'ConfigItemID') -cne $assetId -or
            [string](Get-ZnunyProperty $confirmed[0] 'Name') -ine [string]$asset.Name -or
            [string](Get-ZnunyProperty $confirmed[0] 'Class') -ine [string]$asset.Class) {
            throw 'Gravacao enviada, mas o ativo nao foi confirmado. Confira o CMDB; nao ha reversao automatica.'
        }
        $after = Get-ZnunyProperty $confirmed[0] 'CIXMLData'
        if ([string](Get-ZnunyProperty $confirmed[0] 'DeplState') -cne $deplState -or
            [string](Get-ZnunyProperty $confirmed[0] 'InciState') -cne $inciState) {
            throw 'Um estado mudou durante a operacao. Confira o CMDB; nao repetir nem reverter automaticamente.'
        }
        foreach ($field in $Fields.Keys) {
            if (-not [string]::Equals([string](Get-ZnunyProperty $after $field), $Fields[$field], [StringComparison]::Ordinal)) {
                throw 'Gravacao enviada, mas os valores nao foram confirmados. Confira o CMDB; nao ha reversao automatica.'
            }
        }
        foreach ($property in $before.PSObject.Properties) {
            if ($Fields.ContainsKey($property.Name)) { continue }
            $oldJson = ConvertTo-Json -InputObject $property.Value -Depth 40 -Compress
            if ($null -eq $after -or $null -eq $after.PSObject.Properties[$property.Name]) {
                throw 'Outro campo desapareceu durante a operacao. Confira o CMDB.'
            }
            $newJson = ConvertTo-Json -InputObject (Get-ZnunyProperty $after $property.Name) -Depth 40 -Compress
            if ($oldJson -cne $newJson) {
                throw 'Outro campo mudou durante a operacao. Confira o CMDB; nao repetir nem reverter automaticamente.'
            }
        }
        foreach ($property in $after.PSObject.Properties) {
            if (-not $Fields.ContainsKey($property.Name) -and $null -eq $before.PSObject.Properties[$property.Name]) {
                throw 'Outro campo apareceu durante a operacao. Confira o CMDB.'
            }
        }
        # A API pode nao retornar anexos no GET. Se retornar, conferir sem reenviar.
        foreach ($attachmentKey in @('Attachment','Attachments')) {
            if ($asset.PSObject.Properties[$attachmentKey] -or $confirmed[0].PSObject.Properties[$attachmentKey]) {
                $oldAttachments = ConvertTo-Json -InputObject (Get-ZnunyProperty $asset $attachmentKey) -Depth 40 -Compress
                $newAttachments = ConvertTo-Json -InputObject (Get-ZnunyProperty $confirmed[0] $attachmentKey) -Depth 40 -Compress
                if ($oldAttachments -cne $newAttachments) { throw 'Anexos divergentes. Confira o CMDB.' }
            }
        }
        Write-InstallerLog -Context $Context -Message "Znuny atualizado e relido para $ComputerName. Campos: $((@($changed.Keys) | Sort-Object) -join ', ')." -Level Success
        return $true
    }
    catch {
        # Nao deixar excecoes de conversao, rede ou objetos remotos vazarem dados.
        $message = [string]$_.Exception.Message
        if ($message -match "^Znuny: falha na etapa '(pesquisa|leitura|gravacao|confirmacao)'(?: \(HTTP [0-9]{3}\))?; detalhes sensiveis omitidos\.$") {
            Write-InstallerLog -Context $Context -Message $message -Level Warning
        }
        throw "Znuny: registro nao confirmado na etapa $stage. Confira o CMDB; nao repetir nem reverter automaticamente."
    }
    finally {
        $headers.Clear()
        $apiPassword = $null; $payload = $null; $changed = $null; $Fields = $null
        $asset = $null; $before = $null; $after = $null
    }
}

