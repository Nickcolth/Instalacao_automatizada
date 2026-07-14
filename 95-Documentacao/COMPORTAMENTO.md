# Comportamento do instalador

## Aplicativos

- verifica arquivos, registro e servicos antes de instalar;
- repete a verificacao antes de cada metodo;
- aguarda a deteccao depois da instalacao;
- audita todos os aplicativos planejados ao final;
- tenta novamente somente os aplicativos ausentes;
- registra a evidencia de deteccao nos logs.

## Ordem do Intune

```text
Atlas -> Journey -> Sophos -> Guardian
```

Os quatro aplicativos formam a etapa inicial obrigatoria. O fluxo seguinte somente comeca depois que todos forem detectados.

## SupportAssist

O SupportAssist participa somente do fluxo manual.

## Office

Microsoft 365, Project e Visio sao verificados separadamente.

## Java

```text
1. instalador offline oficial da Oracle
2. WinGet x64
3. Chocolatey
```

A validacao confirma o executavel, o tamanho minimo do instalador e a deteccao depois da instalacao.

## Atalho Desligar

O recurso fica em:

```text
C:\ProgramData\ImagemTI\Recursos\Desligar.vbs
```

Os atalhos sao criados no Menu Iniciar e na Area de Trabalho do colaborador.

## TOPdesk

O arquivo `50-Integracoes\Topdesk\Get_Topdesk.ps1` deve manter o SHA-256:

```text
c65b3b41ed4202a1aef3f7876bb522b8b955df80f6bb09fed4a2cbe745767793
```
