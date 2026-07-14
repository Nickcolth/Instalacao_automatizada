$flagPath = (
    "$env:ProgramData\ImagemTI\Instalador\" +
    'Flags\intune_scheduled_completed.flag'
)

if (-not (Test-Path $flagPath)) {
    exit 1
}

$version = ''

try {
    $version = [string](
        Get-ItemPropertyValue `
            -Path 'HKLM:\SOFTWARE\ImagemTI\Instalador' `
            -Name 'CompletedVersion' `
            -ErrorAction Stop
    )
}
catch {}

if ([string]::IsNullOrWhiteSpace($version)) {
    Write-Output 'Instalacao corporativa concluida.'
}
else {
    Write-Output (
        'Instalacao corporativa concluida. Versao: ' +
        $version
    )
}

exit 0
