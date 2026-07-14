param($Context)

# Remove o usuario comum do grupo local Administradores no inicio do provisionamento.
# - Manual: usa o usuario atual que executou o instalador.
# - IntuneScheduled: a tarefa roda como SYSTEM; por isso identifica o usuario interativo logado.

function Get-AdministratorsGroupName {
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        return ($sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\\')[-1])
    } catch {
        return 'Administradores'
    }
}

function Get-InteractiveUserName {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.UserName) { return [string]$cs.UserName }
    } catch {}

    try {
        $logonUi = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -ErrorAction Stop
        if ($logonUi.LastLoggedOnSAMUser) { return [string]$logonUi.LastLoggedOnSAMUser }
    } catch {}

    return $null
}

function Resolve-TargetUser {
    param($Context)

    if ($Context.Mode -eq 'IntuneScheduled') {
        return Get-InteractiveUserName
    }

    if ($Context.Mode -eq 'Manual') {
        if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { return Get-InteractiveUserName }
        return ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
    }

    return $null
}

function Test-ProtectedAccount {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace($UserName)) { return $true }

    $lowerUser = $UserName.ToLowerInvariant()
    $blockedNames = @(
        '\imagem',
        '\administrator',
        '\administrador',
        'nt authority\system',
        'autoridade nt\sistema'
    )

    foreach ($blocked in $blockedNames) {
        if ($lowerUser.EndsWith($blocked) -or $lowerUser -eq $blocked.TrimStart('\')) { return $true }
    }

    return $false
}

if ($Context.Mode -notin @('Manual','IntuneScheduled')) {
    Write-InstallerLog -Context $Context -Message 'Remocao de administrador do usuario comum ignorada neste modo.'
    return
}

$targetUser = Resolve-TargetUser -Context $Context

if ([string]::IsNullOrWhiteSpace($targetUser)) {
    Write-InstallerLog -Context $Context -Message 'Nao foi possivel identificar o usuario para remover do grupo Administradores.' -Level Warning
    return
}

if (Test-ProtectedAccount -UserName $targetUser) {
    Write-InstallerLog -Context $Context -Message "Usuario '$targetUser' nao sera removido por ser uma conta protegida/administrativa."
    return
}

$adminGroup = Get-AdministratorsGroupName

try {
    $members = Get-LocalGroupMember -Group $adminGroup -ErrorAction Stop
} catch {
    Write-InstallerLog -Context $Context -Message "Nao foi possivel listar membros do grupo '$adminGroup': $($_.Exception.Message)" -Level Warning
    return
}

$alreadyAdmin = $false
foreach ($member in $members) {
    if ([string]$member.Name -ieq $targetUser) { $alreadyAdmin = $true; break }
}

if (-not $alreadyAdmin) {
    Write-InstallerLog -Context $Context -Message "Usuario '$targetUser' nao esta no grupo '$adminGroup'. Nenhuma remocao necessaria."
    return
}

try {
    Remove-LocalGroupMember -Group $adminGroup -Member $targetUser -ErrorAction Stop
    Write-InstallerLog -Context $Context -Message "Usuario '$targetUser' removido do grupo local '$adminGroup' no inicio do provisionamento."
} catch {
    Write-InstallerLog -Context $Context -Message "Falha ao remover '$targetUser' do grupo '$adminGroup': $($_.Exception.Message)" -Level Warning
}
