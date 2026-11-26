# Segredos

Credenciais reais nao devem ser publicadas no repositorio.

O GitHub contem somente:

```text
60-Segredos\Znuny-Producao.config.exemplo.json
```

O pacote privado do Intune inclui:

```text
Fonte\Segredos\Znuny-Producao.config.json
```

Durante a instalacao, o arquivo e copiado para:

```text
C:\ProgramData\ImagemTI\Instalador\Segredos\Znuny-Producao.config.json
```

Fonte privada no fileserver:

```text
\\fileserver\SDK\Softwares\Instalacao_automatizada\Znuny\Znuny-Producao.config.json
```

Use `Host`, `UserLogin` e `Password`. O JSON de tres campos ja usado na consulta
continua compativel. As outras opcoes do exemplo sao opcionais. Nao envie o JSON
preenchido para o GitHub: publique somente o exemplo com login e senha vazios.

O carregador usa a copia privada em `60-Segredos`, quando disponivel no pacote,
ou le diretamente a fonte no fileserver com as permissoes da sessao atual. Nao
ha solicitacao interativa de senha de API. No instalador manual, se a identidade
atual nao conseguir acessar o compartilhamento, a credencial de rede pode ser
solicitada para copiar os segredos. Esse fluxo nao e usado pelo Intune.
No Intune, a identidade que executa a tarefa tambem precisa conseguir ler esse
arquivo, ou receber a copia pelo empacotamento privado ja existente.

O envio de inventario ao n8n pelo agente legado permanece separado. O nome
`Get_Topdesk.ps1` e seu hash nao sao alterados por esta migracao de senhas.
