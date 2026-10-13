Set-StrictMode -Version Latest

$script:ToolVersion = '0.1.0'

function Test-ResurectParams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Drive = '',
        [string]$Share = '',
        [string]$User = '',
        [string]$Folder = 'WinResurect'
    )
    if ($Folder -notmatch '^[A-Za-z0-9._-]+$' -or $Folder -eq '.' -or $Folder -eq '..') {
        throw "Niepoprawna nazwa folderu '$Folder' (dozwolone: litery, cyfry, kropka, myślnik, podkreślnik; bez '..')."
    }
    switch ($Target) {
        'usb' {
            if ($Drive -notmatch '^[A-Za-z]:?$') { throw "Podaj literę dysku USB, np. E: (otrzymano: '$Drive')." }
            $letter = $Drive.Substring(0, 1).ToUpper() + ':'
            return [pscustomobject]@{ Target = 'usb'; Drive = $letter; Share = ''; User = ''; Folder = $Folder }
        }
        'smb' {
            if ($Share -notmatch '^\\\\[^\\]+\\[^\\]+') { throw "Podaj udział w postaci \\serwer\udział (otrzymano: '$Share')." }
            if ([string]::IsNullOrWhiteSpace($User)) { throw 'Podaj użytkownika udziału SMB.' }
            return [pscustomobject]@{ Target = 'smb'; Drive = ''; Share = $Share.TrimEnd('\'); User = $User; Folder = $Folder }
        }
        default { throw "Nieznany cel '$Target' (dozwolone: usb, smb)." }
    }
}

function Get-ImageTarget {
    param(
        [Parameter(Mandatory)]$Params,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][datetime]$Now
    )
    $leaf = '{0}_{1}' -f $ComputerName, $Now.ToString('yyyy-MM-dd_HHmm')
    if ($Params.Target -eq 'usb') {
        $bt = $Params.Drive
        $doc = '{0}\{1}\{2}' -f $Params.Drive, $Params.Folder, $leaf
    }
    else {
        $bt = '{0}\{1}\{2}' -f $Params.Share, $Params.Folder, $leaf
        $doc = $bt
    }
    return [pscustomobject]@{
        BackupTarget = $bt
        DocDir       = $doc
        ImageRoot    = '{0}\WindowsImageBackup\{1}' -f $bt, $ComputerName
        Leaf         = $leaf
    }
}

function Get-WbadminArgs {
    param([Parameter(Mandatory)][string]$BackupTarget, [Parameter(Mandatory)][string[]]$Volumes)
    return @('start', 'backup', "-backupTarget:$BackupTarget", ('-include:' + ($Volumes -join ',')), '-allCritical', '-quiet')
}

function Select-BackupVolumes {
    param([Parameter(Mandatory)][object[]]$Volumes, [string]$TargetDrive = '')
    $skip = if ($TargetDrive) { $TargetDrive.Substring(0, 1).ToUpper() } else { '' }
    $picked = @($Volumes | Where-Object {
            $_.FileSystem -eq 'NTFS' -and $_.DriveType -eq 3 -and $_.Drive.Substring(0, 1).ToUpper() -ne $skip
        })
    return @($picked | ForEach-Object { $_.Drive.Substring(0, 1).ToUpper() + ':' } | Sort-Object)
}

function Get-UsedBytes {
    param([Parameter(Mandatory)][object[]]$Volumes, [Parameter(Mandatory)][string[]]$Selected)
    $sum = [long]0
    foreach ($v in $Volumes) {
        if ($Selected -contains ($v.Drive.Substring(0, 1).ToUpper() + ':')) { $sum += [long]$v.Used }
    }
    return $sum
}
