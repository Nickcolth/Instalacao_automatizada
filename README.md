# Instalacao automatizada corporativa

Versao: **2026.07.14.7**

Este repositorio automatiza a preparacao e a padronizacao de notebooks
Windows utilizados pela empresa.

O instalador pode ser executado manualmente pelo Service Desk ou
automaticamente pelo Microsoft Intune e Windows Autopilot.

## Finalidade

O projeto centraliza:

- instalacao dos agentes corporativos;
- instalacao dos aplicativos utilizados pela empresa;
- configuracoes de sistema e energia;
- criacao e configuracao da conta local de suporte;
- configuracao de recursos da sessao do colaborador;
- inventario e integracao com o TOPdesk;
- validacao dos aplicativos instalados;
- registro de logs e relatorios de execucao.

## Execucao manual

```powershell
irm https://raw.githubusercontent.com/Nickcolth/Instalacao_automatizada/main/i.ps1 | iex
```

## Execucao pelo Intune

O aplicativo Win32 prepara uma tarefa executada como `SYSTEM`.

A tarefa aguarda a area de trabalho do colaborador, baixa a versao atual
do repositorio e executa a instalacao corporativa. Quando existem
pendencias, uma nova verificacao ocorre a cada 15 minutos.

A etapa inicial instala os agentes na seguinte ordem:

```text
Atlas -> Journey -> Sophos -> Guardian
```

## Estrutura

```text
00-Inicializacao    inicializacao e execucao persistente
10-Nucleo           funcoes compartilhadas
20-Configuracoes    aplicativos, empresas, perfis e Office
30-Links            enderecos dos instaladores
40-Tarefas          etapas de preparacao
50-Integracoes      TOPdesk e integracoes auxiliares
60-Segredos         modelos de configuracao
70-Deteccao         scripts de deteccao
80-Recursos         recursos utilizados pelo instalador
85-Ferramentas      diagnosticos e arquivos auxiliares
95-Documentacao     documentacao tecnica
```

## Logs

```text
C:\ProgramData\ImagemTI\Instalador\Logs
```
