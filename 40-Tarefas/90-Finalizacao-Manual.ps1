param($Context)

Write-InstallerLog -Context $Context -Message 'Etapa manual final registrada. O aviso visual/sonoro sera exibido somente no encerramento real do modo Manual, apos a verificacao final.' -Level Warning
Write-InstallerLog -Context $Context -Message 'Confira OneDrive, Outlook, VPN, BitLocker e remova/valide permissoes administrativas conforme o procedimento interno.' -Level Warning


Write-InstallerLog -Context $Context -Message 'As atualizacoes finais de aplicativos e politicas serao executadas automaticamente antes do aviso de encerramento.' -Level Warning
Write-InstallerLog -Context $Context -Message 'Confirme no TOPdesk os dados de senha/status e inventario; depois remova logs sensiveis conforme o procedimento interno.' -Level Warning
