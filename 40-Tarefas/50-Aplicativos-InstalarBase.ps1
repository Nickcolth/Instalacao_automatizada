param($Context)

# No Intune, Firefox, Adobe Acrobat, Office e SupportAssist nao sao instalados por esta tarefa.
# No modo manual, o instalador continua preparando o conjunto completo.
if ($Context.IsIntune) {
    $appNames = @('7zip','google-chrome','java-runtime')
} else {
    $appNames = @('7zip','adobe-reader','google-chrome','firefox','supportassist','java-runtime')
}

Write-InstallerLog -Context $Context -Message "Aplicativos base selecionados: $($appNames -join ', ')"
$null = Invoke-AppInstallSet -Context $Context -AppNames $appNames -StageName 'Aplicativos base'
