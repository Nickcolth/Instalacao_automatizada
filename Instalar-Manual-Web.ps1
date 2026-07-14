[CmdletBinding()]
param(
    [string]$Repositorio = 'Nickcolth/Instalacao_automatizada',
    [string]$Branch = 'main',
    [string]$DiretorioTrabalho = "$env:ProgramData\ImagemTI\Instalador",
    [string]$SegredosOrigem = '\\fileserver\sdk\Softwares\Instalacao_automatizada\TOPdesk',
    [switch]$ManterArquivos
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


function Obter-NomeUsuarioSimples {
    param([string]$Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return '' }
    if ($Nome -like '*\*') { return (($Nome -split '\\')[-1]) }
    return $Nome
}

function Mostrar-AvisoUsuarioImagemBloqueado {
    $mensagem = 'Execucao bloqueada. O instalador nao pode ser executado pelo usuario Imagem. Faca logoff e entre com a conta do colaborador, depois execute novamente.'
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($mensagem, 'Instalador bloqueado - usuario nao permitido', 'OK', 'Warning') | Out-Null
    } catch {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $null = $shell.Popup($mensagem, 120, 'Instalador bloqueado - usuario nao permitido', 48)
        } catch {
            Write-Host $mensagem
        }
    }
}

function Bloquear-SeUsuarioImagem {
    if ((Obter-NomeUsuarioSimples -Nome $env:USERNAME) -ieq 'Imagem') {
        $flagDir = Join-Path $DiretorioTrabalho 'Flags'
        New-Item -Path $flagDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Content -Path (Join-Path $flagDir 'bloqueado_usuario_imagem.flag') -Value (Get-Date -Format o) -Encoding ASCII -Force -ErrorAction SilentlyContinue
        Mostrar-AvisoUsuarioImagemBloqueado
        Write-Host 'Execucao bloqueada: usuario Imagem nao e permitido. Faca logoff e entre com a conta do colaborador.'
        exit 2
    }
}

Bloquear-SeUsuarioImagem

function Testar-Administrador {
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidade)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Executar-ComoAdministrador {
    $argumentos = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Repositorio', "`"$Repositorio`"",
        '-Branch', "`"$Branch`"",
        '-DiretorioTrabalho', "`"$DiretorioTrabalho`"",
        '-SegredosOrigem', "`"$SegredosOrigem`""
    )

    if ($ManterArquivos) { $argumentos += '-ManterArquivos' }

    Start-Process -FilePath 'powershell.exe' -ArgumentList ($argumentos -join ' ') -Verb RunAs
}

function Escrever-Console {
    param(
        [string]$Mensagem,
        [ValidateSet('INFO','OK','AVISO','ERRO')]
        [string]$Nivel = 'INFO'
    )

    $data = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$data][$Nivel] $Mensagem"
}

function Testar-SintaxePowerShell {
    param([Parameter(Mandatory)][string]$Raiz)

    $errosEncontrados = @()
    $arquivos = @(
        Get-ChildItem -Path $Raiz -Recurse -File -ErrorAction Stop |
            Where-Object {
                $_.Extension -in @('.ps1', '.psm1') -and
                $_.FullName -notmatch '[\\/]60-Segredos[\\/]' -and $_.Name -ne 'Get_Topdesk.ps1'
            }
    )

    foreach ($arquivo in $arquivos) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($arquivo.FullName)
            $temByteInvalido = $false

            foreach ($byte in $bytes) {
                if ($byte -eq 0 -or $byte -gt 127) {
                    $temByteInvalido = $true
                    break
                }
            }

            if ($temByteInvalido) {
                $errosEncontrados += "$($arquivo.FullName) - arquivo contem dados binarios ou caracteres fora de ASCII."
                continue
            }

            $tokens = $null
            $erros = $null

            [System.Management.Automation.Language.Parser]::ParseFile(
                $arquivo.FullName,
                [ref]$tokens,
                [ref]$erros
            ) | Out-Null

            $limite = 10
            $contador = 0

            foreach ($erro in @($erros)) {
                if ($contador -ge $limite) { break }

                $linha = $erro.Extent.StartLineNumber
                $coluna = $erro.Extent.StartColumnNumber
                $errosEncontrados += "$($arquivo.FullName) - linha $linha, coluna $coluna - $($erro.Message)"
                $contador++
            }

            if (@($erros).Count -gt $limite) {
                $restantes = @($erros).Count - $limite
                $errosEncontrados += "$($arquivo.FullName) - existem mais $restantes erros de sintaxe nao exibidos."
            }
        }
        catch {
            $errosEncontrados += "$($arquivo.FullName) - falha ao validar arquivo: $($_.Exception.Message)"
        }
    }

    if ($errosEncontrados.Count -gt 0) {
        Escrever-Console 'Foram encontrados erros no pacote baixado:' 'ERRO'

        foreach ($erroEncontrado in $errosEncontrados) {
            Escrever-Console $erroEncontrado 'ERRO'
        }

        throw "Pacote bloqueado por erro de sintaxe ou arquivo corrompido. Total de registros: $($errosEncontrados.Count)"
    }

    Escrever-Console "Validacao de sintaxe concluida. Arquivos verificados: $($arquivos.Count)" 'OK'
}

function Baixar-Arquivo {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destino
    )

    try {
        Start-BitsTransfer -Source $Url -Destination $Destino -ErrorAction Stop
    } catch {
        Invoke-WebRequest -Uri $Url -OutFile $Destino -UseBasicParsing -ErrorAction Stop
    }
}

function Obter-RaizCompartilhamento {
    param([string]$Caminho)

    if ([string]::IsNullOrWhiteSpace($Caminho)) { return $null }
    if ($Caminho -notmatch '^\\\\') { return $null }

    $partes = $Caminho.TrimStart('\\') -split '\\'
    if ($partes.Count -lt 2) { return $null }

    return "\\$($partes[0])\$($partes[1])"
}

function Obter-CaminhoCompletoSeguro {
    param([string]$Caminho)

    try {
        if ([string]::IsNullOrWhiteSpace($Caminho)) { return '' }

        $expandido = [System.Environment]::ExpandEnvironmentVariables($Caminho)

        if (Test-Path -LiteralPath $expandido) {
            return (Resolve-Path -LiteralPath $expandido -ErrorAction Stop).ProviderPath.TrimEnd('\')
        }

        $pai = Split-Path -Path $expandido -Parent
        $nome = Split-Path -Path $expandido -Leaf

        if ($pai -and (Test-Path -LiteralPath $pai)) {
            $paiResolvido = (Resolve-Path -LiteralPath $pai -ErrorAction Stop).ProviderPath.TrimEnd('\')
            return (Join-Path $paiResolvido $nome).TrimEnd('\')
        }

        return $expandido.TrimEnd('\')
    }
    catch {
        return $Caminho.TrimEnd('\')
    }
}

function Testar-MesmoCaminho {
    param(
        [string]$CaminhoA,
        [string]$CaminhoB
    )

    $a = Obter-CaminhoCompletoSeguro -Caminho $CaminhoA
    $b = Obter-CaminhoCompletoSeguro -Caminho $CaminhoB

    if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $false }

    return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
}

function Copiar-ConteudoSeguro {
    param(
        [string]$Origem,
        [string]$Destino
    )

    if ([string]::IsNullOrWhiteSpace($Origem)) { return $false }
    if (-not (Test-Path -LiteralPath $Origem)) { return $false }

    New-Item -Path $Destino -ItemType Directory -Force | Out-Null

    if (Testar-MesmoCaminho -CaminhoA $Origem -CaminhoB $Destino) {
        Escrever-Console "Origem e destino de segredos sao a mesma pasta. Nada precisa ser copiado: $Origem" 'INFO'
        return $true
    }

    $itens = Get-ChildItem -LiteralPath $Origem -Force -ErrorAction SilentlyContinue
    foreach ($item in $itens) {
        $destinoItem = Join-Path $Destino $item.Name

        if (Testar-MesmoCaminho -CaminhoA $item.FullName -CaminhoB $destinoItem) {
            Escrever-Console "Ignorando item de segredo porque origem e destino sao iguais: $($item.Name)" 'INFO'
            continue
        }

        Copy-Item -LiteralPath $item.FullName -Destination $destinoItem -Recurse -Force -ErrorAction Stop
    }

    return $true
}

function Copiar-Segredos {
    param(
        [string]$Origem,
        [string]$Destino,
        [switch]$SolicitarCredencialSeNecessario
    )

    New-Item -Path $Destino -ItemType Directory -Force | Out-Null

    $origensLocais = @(
        "$PSScriptRoot\Segredos",
        "$PSScriptRoot\60-Segredos",
        "$env:ProgramData\ImagemTI\Instalador\Segredos"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($caminho in $origensLocais) {
        if (Test-Path -LiteralPath $caminho) {
            $arquivosSeguros = @(
                Get-ChildItem -LiteralPath $caminho -Recurse -File -ErrorAction SilentlyContinue
            )
            if ($arquivosSeguros.Count -gt 0) {
                Escrever-Console "Copiando arquivos de segredo de: $caminho" 'INFO'
                Copiar-ConteudoSeguro -Origem $caminho -Destino $Destino | Out-Null
                return $true
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Origem)) {
        if (Test-Path -LiteralPath $Origem) {
            $arquivosSeguros = @(
                Get-ChildItem -LiteralPath $Origem -Recurse -File -ErrorAction SilentlyContinue
            )
            if ($arquivosSeguros.Count -gt 0) {
                Escrever-Console "Copiando arquivos de segredo de: $Origem" 'INFO'
                Copiar-ConteudoSeguro -Origem $Origem -Destino $Destino | Out-Null
                return $true
            }
        }

        if ($SolicitarCredencialSeNecessario -and $Origem -match '^\\') {
            Escrever-Console "Nao foi possivel acessar a pasta de segredos com a sessao atual: $Origem" 'AVISO'
            Escrever-Console 'Sera solicitada uma credencial com permissao somente leitura no fileserver.' 'INFO'

            $credencial = Get-Credential -Message "Credencial para acessar $Origem"
            if ($null -eq $credencial) {
                Escrever-Console 'Credencial nao informada. Integracoes como TOPdesk poderao ser ignoradas.' 'AVISO'
                return $false
            }

            $raizCompartilhamento = Obter-RaizCompartilhamento -Caminho $Origem
            if ([string]::IsNullOrWhiteSpace($raizCompartilhamento)) {
                Escrever-Console "Nao foi possivel identificar a raiz do compartilhamento: $Origem" 'ERRO'
                return $false
            }

            $nomeDrive = 'SEGREDOS' + (Get-Random -Minimum 1000 -Maximum 9999)

            try {
                New-PSDrive `
                    -Name $nomeDrive `
                    -PSProvider FileSystem `
                    -Root $raizCompartilhamento `
                    -Credential $credencial `
                    -Scope Script `
                    -ErrorAction Stop | Out-Null

                $origemRelativa = $Origem.Substring($raizCompartilhamento.Length).TrimStart('\\')
                $origemMapeada = if ([string]::IsNullOrWhiteSpace($origemRelativa)) {
                    "${nomeDrive}:\"
                } else {
                    Join-Path "${nomeDrive}:\" $origemRelativa
                }

                if (-not (Test-Path -LiteralPath $origemMapeada)) {
                    Escrever-Console "Credencial aceita, mas a pasta nao foi encontrada: $Origem" 'ERRO'
                    return $false
                }

                $arquivosSeguros = @(
                    Get-ChildItem -LiteralPath $origemMapeada -Recurse -File -ErrorAction SilentlyContinue
                )
                if ($arquivosSeguros.Count -eq 0) {
                    Escrever-Console "Pasta acessivel, mas nenhum arquivo seguro foi encontrado: $Origem" 'AVISO'
                    return $false
                }

                Escrever-Console "Copiando arquivos de segredo do fileserver usando credencial informada." 'INFO'
                Copiar-ConteudoSeguro -Origem $origemMapeada -Destino $Destino | Out-Null
                return $true
            }
            catch {
                Escrever-Console "Falha ao acessar/copiar segredos do fileserver: $($_.Exception.Message)" 'ERRO'
                return $false
            }
            finally {
                if (Get-PSDrive -Name $nomeDrive -ErrorAction SilentlyContinue) {
                    Remove-PSDrive -Name $nomeDrive -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Escrever-Console "Nenhum arquivo de segredo encontrado. Integracoes como TOPdesk poderao ser ignoradas." 'AVISO'
    return $false
}

if (-not (Testar-Administrador)) {
    Escrever-Console 'Reabrindo como administrador...' 'INFO'
    Executar-ComoAdministrador
    exit 0
}

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$raizExecucao = Join-Path $DiretorioTrabalho "Manual-Web-$runId"
$caminhoZip = Join-Path $raizExecucao 'repositorio.zip'
$caminhoExtracao = Join-Path $raizExecucao 'codigo'
$caminhoSegredosLocal = Join-Path $DiretorioTrabalho 'Segredos'

New-Item -Path $raizExecucao, $caminhoExtracao, $caminhoSegredosLocal -ItemType Directory -Force | Out-Null

try {
    Escrever-Console "Preparando execucao manual via GitHub. Repositorio: $Repositorio. Branch: $Branch." 'INFO'

    Copiar-Segredos -Origem $SegredosOrigem -Destino $caminhoSegredosLocal -SolicitarCredencialSeNecessario | Out-Null

    $urlZip = "https://github.com/$Repositorio/archive/refs/heads/$Branch.zip"
    Escrever-Console "Baixando pacote do GitHub: $urlZip" 'INFO'
    Baixar-Arquivo -Url $urlZip -Destino $caminhoZip

    Escrever-Console 'Extraindo pacote...' 'INFO'
    Expand-Archive -Path $caminhoZip -DestinationPath $caminhoExtracao -Force

    $repoExtraido = Get-ChildItem -Path $caminhoExtracao -Directory | Select-Object -First 1
    if (-not $repoExtraido) { throw 'Nao foi possivel localizar a pasta extraida do repositorio.' }

    $moduloDuplicadoRaiz = Join-Path $repoExtraido.FullName 'Instalador.Nucleo.psm1'
    $moduloCorreto = Join-Path $repoExtraido.FullName '10-Nucleo\Instalador.Nucleo.psm1'

    if (Test-Path $moduloDuplicadoRaiz) {
        Escrever-Console "Arquivo duplicado encontrado na raiz e removido antes da validacao: $moduloDuplicadoRaiz" 'AVISO'
        Remove-Item -Path $moduloDuplicadoRaiz -Force -ErrorAction Stop
    }

    if (-not (Test-Path $moduloCorreto)) {
        throw "Modulo principal nao encontrado no caminho correto: $moduloCorreto"
    }

    $segredosDestinoRepositorio = Join-Path $repoExtraido.FullName '60-Segredos'
    if (Test-Path $caminhoSegredosLocal) {
        New-Item -Path $segredosDestinoRepositorio -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $caminhoSegredosLocal '*') -Destination $segredosDestinoRepositorio -Recurse -Force -ErrorAction SilentlyContinue
    }

    Escrever-Console 'Validando sintaxe dos scripts baixados...' 'INFO'

    Testar-SintaxePowerShell -Raiz $repoExtraido.FullName



    $entrada = Join-Path $repoExtraido.FullName 'Executar-Instalador.ps1'
    if (-not (Test-Path $entrada)) { throw "Arquivo de entrada nao encontrado: $entrada" }

    $versionPath = Join-Path $repoExtraido.FullName 'VERSION.txt'
    $packageVersion = 'sem-versao'

    if (Test-Path $versionPath) {
        $packageVersion = (
            Get-Content `
                -Path $versionPath `
                -Raw `
                -Encoding UTF8
        ).Trim()
    }

    Escrever-Console 'Iniciando instalacao em modo Manual...' 'INFO'

    & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $entrada `
        -Mode Manual `
        -RepositoryRoot $repoExtraido.FullName `
        -PackageVersion $packageVersion

    $codigoSaida = $LASTEXITCODE

    if ($codigoSaida -eq 0) {
        Escrever-Console 'Instalacao manual concluida com sucesso.' 'OK'
        if (-not $ManterArquivos) {
            Remove-Item -Path $raizExecucao -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Escrever-Console "Instalacao finalizada com pendencias ou erro. Codigo de saida: $codigoSaida" 'ERRO'
        Escrever-Console "Arquivos da execucao preservados em: $raizExecucao" 'AVISO'
    }

    exit $codigoSaida
}
catch {
    Escrever-Console "Falha critica no bootstrap manual web: $($_.Exception.Message)" 'ERRO'
    Escrever-Console "Arquivos da execucao preservados em: $raizExecucao" 'AVISO'
    exit 1
}
