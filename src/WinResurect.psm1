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
        [void]$errors.Add('BitLocker włączony: potwierdź, że klucz odzyskiwania jest zapisany poza tą kopią.')
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
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return $false }
    $f = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { ($_.Extension -eq '.vhdx' -or $_.Extension -eq '.vhd') -and $_.Length -gt 0 })
    return ($f.Count -gt 0)
}
