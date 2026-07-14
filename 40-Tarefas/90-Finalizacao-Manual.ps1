param($Context)

Write-InstallerLog -Context $Context -Message 'Etapa manual final registrada. O aviso visual/sonoro sera exibido somente no encerramento real do modo Manual, apos a verificacao final.' -Level Warning
Write-InstallerLog -Context $Context -Message 'Confira OneDrive, Outlook, VPN, BitLocker e remova/valide permissoes administrativas conforme o procedimento interno.' -Level Warning


Write-InstallerLog -Context $Context -Message 'Checklist original: execute winget upgrade --all --accept-package-agreements --accept-source-agreements quando aplicavel.' -Level Warning
Write-InstallerLog -Context $Context -Message 'Checklist original: execute gpupdate /force nos equipamentos que ainda dependem de politicas do dominio local.' -Level Warning
Write-InstallerLog -Context $Context -Message 'Confirme no TOPdesk os dados de senha/status e inventario; depois remova logs sensiveis conforme o procedimento interno.' -Level Warning
