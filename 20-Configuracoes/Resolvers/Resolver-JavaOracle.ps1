param(
    $Context,
    $Manifest,
    [string]$Name
)

$ErrorActionPreference = 'Stop'

$officialUrl = (
    'https://javadl.oracle.com/webapps/download/AutoDL?BundleId=253608_2fde65a2208f40a5b5f4c844b0dff092'
)

$uri = [Uri]$officialUrl

if (
    $uri.Scheme -ne 'https' -or
    $uri.Host -ne 'javadl.oracle.com' -or
    $officialUrl -notmatch
    '/webapps/download/AutoDL\?BundleId='
) {
    throw 'O link configurado do Java nao e um link oficial valido.'
}

Write-InstallerLog `
    -Context $Context `
    -Message (
        "Usando instalador oficial de contingencia do Java 8 Update 503 x64: " +
        "$officialUrl"
    ) `
    -Level Success

return $officialUrl
