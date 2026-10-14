Set-StrictMode -Version Latest

$script:ToolVersion = '0.1.0'

function Get-ToolVersion { return $script:ToolVersion }

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
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Volumes, [string]$TargetDrive = '')
    $skip = if ($TargetDrive) { $TargetDrive.Substring(0, 1).ToUpper() } else { '' }
    $picked = @($Volumes | Where-Object {
            $_.FileSystem -eq 'NTFS' -and $_.DriveType -eq 3 -and $_.Drive.Substring(0, 1).ToUpper() -ne $skip
        })
    return @($picked | ForEach-Object { $_.Drive.Substring(0, 1).ToUpper() + ':' } | Sort-Object)
}

function Get-UsedBytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Volumes, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Selected)
    $sum = [long]0
    foreach ($v in $Volumes) {
        if ($Selected -contains ($v.Drive.Substring(0, 1).ToUpper() + ':')) { $sum += [long]$v.Used }
    }
    return $sum
}

function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return ($Bytes / 1GB).ToString('N1', $inv) + ' GB' }
    if ($Bytes -ge 1MB) { return ($Bytes / 1MB).ToString('N0', $inv) + ' MB' }
    return ($Bytes / 1KB).ToString('N0', $inv) + ' KB'
}

function Hide-Secrets {
    param([string]$Text, [string[]]$Secrets = @())
    if (-not $Text) { return '' }
    $t = $Text
    foreach ($s in @($Secrets | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending)) {
        $t = $t.Replace($s, '***')
    }
    return ($t -replace '(?i)(/pass(?:word)?:|-password:|password=|has[łl]o=)\S+', '$1***')
}

function Test-Preflight {
    param([Parameter(Mandatory)]$Facts)
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    if (-not $Facts.IsAdmin) { [void]$errors.Add('Uruchom jako administrator (Start.cmd robi to automatycznie).') }
    if (-not $Facts.HasWbadmin) { [void]$errors.Add('Brak narzędzia wbadmin w tym systemie.') }
    if (@($Facts.Volumes).Count -eq 0) { [void]$errors.Add('Nie znaleziono woluminów NTFS do skopiowania.') }
    if ($Facts.Target -eq 'usb') {
        if (-not $Facts.TargetFound) { [void]$errors.Add('Nie znaleziono dysku docelowego USB (sprawdź literę dysku).') }
        elseif ($Facts.TargetFileSystem -ne 'NTFS') { [void]$errors.Add("Dysk USB musi być w NTFS (jest: '$($Facts.TargetFileSystem)').") }
        if ($Facts.TargetIsSystemDisk) { [void]$errors.Add('Cel leży na tym samym fizycznym dysku, co kopiowany system.') }
        if ($Facts.TargetIsSystemDrive) { [void]$errors.Add('Cel nie może być dyskiem systemowym.') }
        if ($Facts.TargetDiskUnknown) { [void]$warnings.Add('Nie można ustalić fizycznego dysku celu - upewnij się, że nie jest to ten sam dysk, co kopiowany system.') }
    }
    $need = [long]($Facts.UsedBytes * 1.1)
    if ($null -eq $Facts.TargetFreeBytes) {
        [void]$warnings.Add("Nie można sprawdzić wolnego miejsca na celu — upewnij się, że jest co najmniej $(Format-Size $need).")
    }
    elseif ($Facts.TargetFreeBytes -lt $need) {
        [void]$errors.Add("Za mało miejsca na celu: potrzeba ok. $(Format-Size $need), wolne $(Format-Size ([long]$Facts.TargetFreeBytes)).")
    }
    if ($Facts.OnBattery) { [void]$warnings.Add('Komputer pracuje na baterii — podłącz zasilanie.') }
    if ($Facts.BitLockerProtected -and -not $Facts.BitLockerKeyConfirmed) {
        [void]$errors.Add('BitLocker włączony (lub nie udało się ustalić stanu): potwierdź, że klucz odzyskiwania jest zapisany poza tą kopią.')
    }
    return [pscustomobject]@{ Errors = @($errors); Warnings = @($warnings) }
}

function New-Manifest {
    param([Parameter(Mandatory)]$Info)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $bl = if ($Info.BitLocker) { 'tak (klucz nie jest zapisywany na nośniku z kopią)' } else { 'nie' }
    $lines = @(
        'win_resurect - manifest kopii',
        "Wersja narzędzia: $($Info.ToolVersion)",
        "Komputer: $($Info.ComputerName)",
        "System: $($Info.OsCaption) ($($Info.OsVersion))",
        "Data: $($Info.Date.ToString('yyyy-MM-dd HH:mm', $inv))",
        "Cel: $($Info.Target) - $($Info.BackupTarget)",
        "Wynik: $($Info.Status)",
        "Czas: $([int]$Info.DurationSec) s",
        "BitLocker: $bl",
        'Woluminy:'
    )
    foreach ($v in $Info.Volumes) { $lines += "  $($v.Drive)  użyte: $(Format-Size ([long]$v.Used))" }
    $skipped = @(if ($Info.PSObject.Properties['Skipped']) { $Info.Skipped })
    if ($skipped.Count -gt 0) {
        $lines += 'Pominięte woluminy:'
        foreach ($sv in $skipped) { $lines += "  $($sv.Drive)  $($sv.Reason) - NIE ma w kopii" }
    }
    return ($lines -join "`r`n") + "`r`n"
}

function New-RestoreInstructions {
    param([Parameter(Mandatory)]$Info)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Info.Target -eq 'usb') {
        $where = "dysk USB $($Info.Drive), katalog główny, folder WindowsImageBackup\$($Info.ComputerName)"
        $pick = 'Wybierz obraz systemu (dysk USB powinien być widoczny na liście).'
    }
    else {
        $where = "udział $($Info.BackupTarget), folder WindowsImageBackup\$($Info.ComputerName)"
        $pick = "Wybierz: Zaawansowane -> Wyszukaj obraz systemu w sieci i podaj ścieżkę $($Info.BackupTarget) oraz dane dostępu do udziału."
    }
    $lines = @(
        "PRZYWRACANIE - kopia komputera $($Info.ComputerName) z $($Info.Date.ToString('yyyy-MM-dd HH:mm', $inv))",
        '',
        "Gdzie leży kopia: $where",
        '',
        'PEŁNE ODTWORZENIE (nadpisze dysk komputera!)',
        '1. Podłącz nośnik z kopią (USB) albo upewnij się, że udział sieciowy jest dostępny.',
        '2. Uruchom środowisko odzyskiwania: Ustawienia -> System -> Odzyskiwanie -> Uruchamianie zaawansowane -> Uruchom ponownie teraz',
        '   (albo uruchom z pendrive''a instalacyjnego Windows i wybierz Napraw komputer).',
        '3. Rozwiązywanie problemów -> Opcje zaawansowane -> Więcej opcji odzyskiwania -> Odzyskiwanie obrazu systemu.',
        "4. $pick",
        '5. Jeśli dysk był szyfrowany BitLockerem, przygotuj klucz odzyskiwania BitLocker (nie jest zapisany na tym nośniku).',
        '6. Potwierdź odtworzenie i poczekaj na zakończenie. Komputer uruchomi się ponownie.',
        '',
        'POJEDYNCZE PLIKI (bez odtwarzania całości)',
        '1. Znajdź plik .vhdx w folderze WindowsImageBackup\<komputer>\Backup <data>.',
        '2. W PowerShellu jako administrator: Mount-DiskImage -ImagePath "<pełna ścieżka do .vhdx>" -Access ReadOnly',
        '3. Skopiuj potrzebne pliki z nowego dysku, który pojawi się w Eksploratorze.',
        '4. Odmontuj: Dismount-DiskImage -ImagePath "<pełna ścieżka do .vhdx>"',
        '',
        'UWAGI: odtwarzanie na innym sprzęcie nie jest gwarantowane; stare serwery plików wymagające SMB1 nie zostaną',
        'zamontowane w środowisku odzyskiwania - użyj wtedy kopii na USB.'
    )
    return ($lines -join "`r`n") + "`r`n"
}

function Test-ImageFilePresent {
    param([Parameter(Mandatory)][string]$Root, [datetime]$NotOlderThan = [datetime]::MinValue)
    if (-not (Test-Path -LiteralPath $Root)) { return $false }
    $f = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { ($_.Extension -eq '.vhdx' -or $_.Extension -eq '.vhd') -and $_.Length -gt 0 -and $_.LastWriteTime -ge $NotOlderThan })
    return ($f.Count -gt 0)
}

function ConvertTo-BitLockerState {
    param($ProtectionStatus, $EncryptionPercentage, [string]$VolumeStatus)
    if ($null -ne $ProtectionStatus -and [int]$ProtectionStatus -eq 1) { return 'On' }
    if ($null -ne $EncryptionPercentage -and [int]$EncryptionPercentage -gt 0) { return 'On' }
    if ($VolumeStatus -and $VolumeStatus -ne 'FullyDecrypted') { return 'On' }
    return 'Off'
}

function Get-ShareRoot {
    param([Parameter(Mandatory)][string]$Share)
    if ($Share -match '^(\\\\[^\\]+\\[^\\]+)') { return $Matches[1] }
    return $Share
}

function Get-SkippedVolumes {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Volumes,
        [AllowEmptyCollection()][string[]]$Selected = @(),
        [string]$TargetDrive = ''
    )
    $target = if ($TargetDrive) { $TargetDrive.Substring(0, 1).ToUpper() + ':' } else { '' }
    $out = @()
    foreach ($v in $Volumes) {
        $d = $v.Drive.Substring(0, 1).ToUpper() + ':'
        if (($Selected -contains $d) -or $d -eq $target) { continue }
        if ($v.DriveType -ne 3) { $reason = 'dysk wymienny lub inny typ nośnika' }
        elseif (-not $v.FileSystem) { $reason = 'nieznany system plików lub wolumin zablokowany (BitLocker)' }
        else { $reason = "system plików $($v.FileSystem) (kopiowany jest tylko NTFS)" }
        $out += [pscustomobject]@{ Drive = $d; Reason = $reason }
    }
    return $out
}

function Get-NetworkErrorText {
    param([Parameter(Mandatory)][int]$Code)
    switch ($Code) {
        0 { return 'OK' }
        5 { return 'odmowa dostępu' }
        53 { return 'nie znaleziono ścieżki sieciowej' }
        86 { return 'błędne hasło' }
        1219 { return 'istnieje już połączenie z tym serwerem na innych poświadczeniach (odłącz je poleceniem: net use <udział> /delete)' }
        1326 { return 'błędny użytkownik lub hasło' }
        default { return "błąd Windows $Code" }
    }
}

$script:NativeSource = @'
using System;
using System.Runtime.InteropServices;
namespace WinResurect {
    public static class Native {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct NETRESOURCE {
            public int dwScope; public int dwType; public int dwDisplayType; public int dwUsage;
            public string lpLocalName; public string lpRemoteName; public string lpComment; public string lpProvider;
        }
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        public static extern int WNetAddConnection2(ref NETRESOURCE r, string password, string username, int flags);
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        public static extern int WNetCancelConnection2(string name, int flags, bool force);
    }
}
'@

function Connect-NetworkShare {
    # Hasło trafia do WinAPI, a nie do wiersza poleceń żadnego procesu.
    param([Parameter(Mandatory)][string]$Share, [Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Password)
    if (-not ('WinResurect.Native' -as [type])) { Add-Type -TypeDefinition $script:NativeSource }
    $r = New-Object WinResurect.Native+NETRESOURCE
    $r.dwType = 1
    $r.lpRemoteName = $Share
    $rc = [WinResurect.Native]::WNetAddConnection2([ref]$r, $Password, $User, 0)
    return @{ ExitCode = [int]$rc; Output = @(Get-NetworkErrorText -Code ([int]$rc)) }
}

function Disconnect-NetworkShare {
    param([Parameter(Mandatory)][string]$Share)
    if (-not ('WinResurect.Native' -as [type])) { Add-Type -TypeDefinition $script:NativeSource }
    $rc = [WinResurect.Native]::WNetCancelConnection2($Share, 0, $true)
    return @{ ExitCode = [int]$rc; Output = @(Get-NetworkErrorText -Code ([int]$rc)) }
}


function Invoke-ResurectBackup {
    param(
        [Parameter(Mandatory)]$Params,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Facts,
        [Parameter(Mandatory)][string[]]$Volumes,
        [Parameter(Mandatory)][scriptblock]$Runner,
        [System.Management.Automation.PSCredential]$Credential = $null,
        [scriptblock]$Connector = { param($Share, $User, $Password) Connect-NetworkShare -Share $Share -User $User -Password $Password },
        [scriptblock]$Disconnector = { param($Share) Disconnect-NetworkShare -Share $Share },
        [string]$ComputerName = $env:COMPUTERNAME,
        [datetime]$Now = (Get-Date),
        [string]$OsCaption = '',
        [string]$OsVersion = '',
        [object[]]$VolumeInfo = @(),
        [object[]]$SkippedInfo = @()
    )
    $plain = if ($Credential) { $Credential.GetNetworkCredential().Password } else { '' }
    $shareRoot = if ($Params.Target -eq 'smb') { Get-ShareRoot -Share $Params.Share } else { '' }
    $log = New-Object System.Collections.ArrayList
    $secrets = @($plain)
    $say = { param($m) [void]$log.Add((Hide-Secrets -Text $m -Secrets $secrets)) }
    $started = Get-Date
    $code = 0
    $status = 'OK'
    $connected = $false
    $smb = ($Params.Target -eq 'smb')
    try {
        $pf = Test-Preflight -Facts $Facts
        foreach ($w in $pf.Warnings) { & $say "Ostrzeżenie: $w" }
        foreach ($sv in @($SkippedInfo)) { & $say "Ostrzeżenie: pominięto wolumin $($sv.Drive) - $($sv.Reason)" }
        if ($pf.Errors.Count -gt 0) {
            foreach ($e in $pf.Errors) { & $say "Błąd: $e" }
            $code = 2; $status = 'PRZERWANO (kontrole przed startem)'
        }
        if ($code -eq 0 -and $smb -and -not $plain) {
            & $say 'Błąd: podaj użytkownika i hasło do udziału SMB.'
            $code = 2; $status = 'PRZERWANO (brak hasła)'
        }
        if ($code -eq 0 -and $smb) {
            $c = & $Connector $shareRoot $Params.User $plain
            if ($c.ExitCode -ne 0) {
                $why = (@($c.Output) -join ' ')
                & $say "Błąd: nie można połączyć się z udziałem SMB (kod $($c.ExitCode)): $why"
                $code = 2; $status = 'PRZERWANO (brak połączenia z udziałem)'
            }
            else { $connected = $true; & $say "Połączono z udziałem $shareRoot." }
        }
        $driversDir = Join-Path $Target.DocDir 'drivers'
        if ($code -eq 0) {
            try { New-Item -ItemType Directory -Force -Path $driversDir -ErrorAction Stop | Out-Null }
            catch {
                & $say 'Błąd: nie można utworzyć katalogu na nośniku docelowym.'
                $code = 2; $status = 'PRZERWANO (brak zapisu na nośniku)'
            }
        }
        if ($code -eq 0) {
            $d = & $Runner 'pnputil' @('/export-driver', '*', $driversDir)
            if ($d.ExitCode -ne 0) { & $say 'Ostrzeżenie: eksport sterowników nie powiódł się.' }
            else { & $say 'Wyeksportowano sterowniki.' }
        }
        if ($code -eq 0) {
            & $say "Start kopii obrazu: $($Volumes -join ', ') -> $($Target.BackupTarget)"
            $w = & $Runner 'wbadmin' (Get-WbadminArgs -BackupTarget $Target.BackupTarget -Volumes $Volumes)
            if ($w.ExitCode -ne 0) {
                $tail = (@($w.Output | Where-Object { $_ } | Select-Object -Last 3) -join ' | ')
                & $say "Błąd: wbadmin zakończył się kodem $($w.ExitCode): $tail"
                $code = 1; $status = 'BŁĄD (wbadmin)'
            }
        }
        if ($code -eq 0) {
            $v = & $Runner 'wbadmin' @('get', 'versions', "-backupTarget:$($Target.BackupTarget)")
            $listed = ($v.ExitCode -eq 0) -and ((@($v.Output) -join "`n") -match '\d{1,2}/\d{1,2}/\d{4}-\d{1,2}:\d{2}')
            $present = Test-ImageFilePresent -Root $Target.ImageRoot -NotOlderThan $started.AddMinutes(-15)
            if ($listed -and $present) { & $say 'Weryfikacja: kopia widoczna w wbadmin, plik obrazu istnieje.' }
            else {
                & $say 'Błąd: weryfikacja kopii nie powiodła się (brak wersji w wbadmin lub brak pliku obrazu).'
                $code = 1; $status = 'BŁĄD (weryfikacja)'
            }
        }
        if (Test-Path -LiteralPath $Target.DocDir) {
            try {
                $info = [pscustomobject]@{
                    ToolVersion = $script:ToolVersion; ComputerName = $ComputerName; OsCaption = $OsCaption; OsVersion = $OsVersion
                    Date = $Now; Target = $Params.Target; Drive = $Params.Drive; BackupTarget = $Target.BackupTarget
                    Status = $status; DurationSec = ((Get-Date) - $started).TotalSeconds
                    Volumes = @($VolumeInfo); Skipped = @($SkippedInfo); BitLocker = [bool]$Facts.BitLockerProtected
                }
                Set-Content -LiteralPath (Join-Path $Target.DocDir 'manifest.txt') -Value (New-Manifest -Info $info) -Encoding UTF8
                if ($code -eq 0) {
                    Set-Content -LiteralPath (Join-Path $Target.DocDir 'PRZYWRACANIE.txt') -Value (New-RestoreInstructions -Info $info) -Encoding UTF8
                }
                Set-Content -LiteralPath (Join-Path $Target.DocDir 'log.txt') -Value @($log) -Encoding UTF8
            }
            catch { & $say 'Ostrzeżenie: nie udało się zapisać dokumentów na nośniku.' }
        }
    }
    finally {
        if ($connected) {
            try { & $Disconnector $shareRoot | Out-Null; & $say 'Odłączono udział.' } catch { }
        }
    }
    return [pscustomobject]@{ ExitCode = $code; Status = $status; DocDir = $Target.DocDir; Messages = @($log) }
}

function Get-LocalVolumes {
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 -or $_.DriveType -eq 3 })
    foreach ($d in $disks) {
        $size = [long]$d.Size
        $free = [long]$d.FreeSpace
        [pscustomobject]@{
            Drive      = [string]$d.DeviceID
            FileSystem = [string]$d.FileSystem
            DriveType  = [int]$d.DriveType
            Label      = [string]$d.VolumeName
            Size       = $size
            Free       = $free
            Used       = [long]($size - $free)
        }
    }
}

function Get-DiskNumber {
    param([Parameter(Mandatory)][string]$Drive)
    try { return [int](Get-Partition -DriveLetter $Drive.Substring(0, 1) -ErrorAction Stop | Get-Disk).Number }
    catch { return $null }
}

function Test-BitLockerProtected {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Volumes)
    foreach ($v in $Volumes) {
        $state = 'Unknown'
        try {
            $s = Get-BitLockerVolume -MountPoint $v -ErrorAction Stop
            $state = ConvertTo-BitLockerState -ProtectionStatus ([int]$s.ProtectionStatus) -EncryptionPercentage $s.EncryptionPercentage -VolumeStatus ([string]$s.VolumeStatus)
        }
        catch {
            try {
                $ev = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$v'" -ErrorAction Stop
                $ps = [int](Invoke-CimMethod -InputObject $ev -MethodName GetProtectionStatus -ErrorAction Stop).ProtectionStatus
                $cs = Invoke-CimMethod -InputObject $ev -MethodName GetConversionStatus -ErrorAction Stop
                $vs = if ([int]$cs.ConversionStatus -eq 0) { 'FullyDecrypted' } else { 'Encrypted' }
                $state = ConvertTo-BitLockerState -ProtectionStatus $ps -EncryptionPercentage ([int]$cs.EncryptionPercentage) -VolumeStatus $vs
            }
            catch { $state = 'Unknown' }
        }
        # 'Unknown' traktujemy jak szyfrowany: lepiej zapytać o klucz niż założyć, że go nie trzeba.
        if ($state -ne 'Off') { return $true }
    }
    return $false
}

function Test-OnBattery {
    $b = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    if ($b.Count -eq 0) { return $false }
    return (@($b | Where-Object { $_.BatteryStatus -eq 1 }).Count -gt 0)
}

function Get-ResurectFacts {
    param([Parameter(Mandatory)]$Params, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllVolumes, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Selected)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $found = $true; $fs = ''; $free = $null; $sameDisk = $false; $isSystemDrive = $false; $diskUnknown = $false
    if ($Params.Target -eq 'usb') {
        $tv = $AllVolumes | Where-Object { $_.Drive -eq $Params.Drive } | Select-Object -First 1
        if ($tv) { $fs = $tv.FileSystem; $free = [long]$tv.Free } else { $found = $false }
        $isSystemDrive = ($Params.Drive -eq "$env:SystemDrive".ToUpper())
        $targetDisk = Get-DiskNumber -Drive $Params.Drive
        if ($null -eq $targetDisk) { $diskUnknown = $true }
        else {
            foreach ($s in $Selected) { if ((Get-DiskNumber -Drive $s) -eq $targetDisk) { $sameDisk = $true } }
        }
    }
    return [pscustomobject]@{
        IsAdmin               = [bool]$isAdmin
        HasWbadmin            = [bool](Get-Command wbadmin.exe -ErrorAction SilentlyContinue)
        Volumes               = @($Selected)
        Target                = $Params.Target
        TargetFound           = $found
        TargetFileSystem      = $fs
        TargetIsSystemDisk    = $sameDisk
        TargetFreeBytes       = $free
        UsedBytes             = (Get-UsedBytes -Volumes $AllVolumes -Selected $Selected)
        OnBattery             = (Test-OnBattery)
        BitLockerProtected    = (Test-BitLockerProtected -Volumes $Selected)
        BitLockerKeyConfirmed = $false
        TargetIsSystemDrive   = $isSystemDrive
        TargetDiskUnknown     = $diskUnknown
    }
}
