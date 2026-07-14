param(
    $Context,
    $Manifest,
    [string]$Name
)

$ErrorActionPreference = 'Stop'

$officialUrl = (
    'https://javadl.oracle.com/webapps/download/AutoDL?BundleId=253195_f7fe8e644f724108bdb54139381e29a7'
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
        "Usando instalador oficial fixo do Java 8 x64: " +
        "$officialUrl"
    ) `
    -Level Success

return $officialUrl
