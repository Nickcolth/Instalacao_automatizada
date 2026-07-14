$flagPath = (
    "$env:ProgramData\ImagemTI\Instalador\" +
    "Flags\intune_scheduled_completed.flag"
)

$baseKey = $null
$registryKey = $null

try {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )

    $registryKey = $baseKey.OpenSubKey(
        'SOFTWARE\ImagemTI\Instalador',
        $false
    )

    if ($null -ne $registryKey) {
        $status = [string]$registryKey.GetValue(
            'FullInstallStatus',
            ''
        )

        $completedVersion = [string]$registryKey.GetValue(
            'CompletedVersion',
            ''
        )

        if (
            $status -eq 'Completed' -and
            -not [string]::IsNullOrWhiteSpace($completedVersion) -and
            (Test-Path $flagPath)
        ) {
            Write-Output (
                "Instalacao corporativa completa. Versao: " +
                $completedVersion
            )

            exit 0
        }
    }
}
catch {}
finally {
    if ($null -ne $registryKey) {
        $registryKey.Dispose()
    }

    if ($null -ne $baseKey) {
        $baseKey.Dispose()
    }
}

exit 1
