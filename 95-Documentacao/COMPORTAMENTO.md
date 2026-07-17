# Comportamento do instalador

## Execucao pelo Intune

O aplicativo Win32 cria e inicia uma tarefa persistente como `SYSTEM`.

A tarefa executa duas fases:

```text
Fase critica durante o provisionamento:
Atlas -> Journey -> Sophos -> Guardian

Fase completa depois do desktop:
aplicativos, configuracoes, inventario e sessao do colaborador
```

A fase completa somente comeca quando os quatro agentes forem detectados
e a Area de Trabalho real do colaborador estiver pronta.

Quando a fase critica nao e concluida, a tarefa insiste de
novo a cada 60 segundos. Depois dela, as demais pendencias
continuam sendo verificadas a cada 15 minutos.

## Aplicativos

- verifica arquivos, registro e servicos antes de instalar;
- repete a verificacao antes de cada metodo;
- aguarda a deteccao depois da instalacao;
- audita todos os aplicativos planejados ao final;
- tenta novamente somente os aplicativos ausentes;
- registra a evidencia de deteccao nos logs.

## SupportAssist

O SupportAssist participa somente do fluxo manual.

Antes da instalação, o Windows informa o fabricante e o modelo do
equipamento.

O aplicativo somente é instalado e auditado em equipamentos:

```text
Dell
Alienware
```

Em outras marcas, ou quando o fabricante não puder ser identificado, o
SupportAssist é ignorado e não é registrado como pendente.

## Acompanhamento de processos demorados

Downloads e instaladores em execução registram uma atualização a cada
60 segundos.

O log informa:

- tempo decorrido;
- processo e PID;
- consumo acumulado de CPU;
- tamanho parcial do arquivo durante downloads;
- tamanho dos dados preparados pelo Office.

Esse acompanhamento é informativo e não interfere na execução do
instalador.

## Métodos alternativos de instalação

Para os aplicativos compatíveis, a ordem utilizada é:

```text
instalador oficial direto
→ WinGet
→ Chocolatey
```

A detecção é refeita antes de cada método. Quando um método conclui a
instalação, os métodos seguintes não são executados.

O Chocolatey é preparado automaticamente quando estiver ausente. Caso
a preparação não seja possível, os métodos direto e WinGet continuam
disponíveis e uma nova tentativa é realizada quando necessário.

O Office utiliza o `setup.exe` direto da CDN da Microsoft e um extrator
oficial do Office Deployment Tool como origem alternativa. A página do
Download Center é apenas uma consulta adicional e não bloqueia a
instalação.

## Office

Microsoft 365, Project e Visio sao verificados separadamente.

## Java

```text
1. instalador offline oficial da Oracle
2. WinGet x64
```

A validacao confirma o executavel, o tamanho minimo do instalador e a
deteccao depois da instalacao.

## Atalho Desligar

O recurso fica em:

```text
C:\ProgramData\ImagemTI\Recursos\Desligar.vbs
```

Os atalhos sao criados no Menu Iniciar e na Area de Trabalho do
colaborador.

## TOPdesk

O arquivo `50-Integracoes\Topdesk\Get_Topdesk.ps1` deve manter o
SHA-256:

```text
c65b3b41ed4202a1aef3f7876bb522b8b955df80f6bb09fed4a2cbe745767793
```


## Processos demorados

Durante downloads ou instalacoes longas, o log registra a cada 60
segundos que o processo continua ativo, incluindo tempo decorrido, nome
do processo e PID.
