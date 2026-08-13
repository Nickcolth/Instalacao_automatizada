param($Context)

# No Intune, Firefox, Adobe Acrobat, Office e SupportAssist nao sao instalados por esta tarefa.
# O .NET Desktop Runtime 10.0.11 faz parte do conjunto padrao nos dois fluxos.
if ($Context.IsIntune) {
    $appNames = @(
        '7zip',
        'google-chrome',
        'java-runtime',
        'dotnet-desktop-runtime-10'
    )
} else {
    $appNames = @(
        '7zip',
        'adobe-reader',
        'google-chrome',
        'firefox',
        'supportassist',
        'java-runtime',
        'dotnet-desktop-runtime-10'
    )
}

Write-InstallerLog -Context $Context -Message "Aplicativos base selecionados: $($appNames -join ', ')"
$null = Invoke-AppInstallSet -Context $Context -AppNames $appNames -StageName 'Aplicativos base'
