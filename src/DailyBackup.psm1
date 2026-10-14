Set-StrictMode -Version Latest

function Get-ConfigValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function ConvertTo-IntOrNull {
    param($Value)
    $i = 0
    if ($null -ne $Value -and [int]::TryParse([string]$Value, [ref]$i)) { return $i }
    return $null
}

function ConvertTo-DailyConfig {
    param($Raw)
    $t = Get-ConfigValue $Raw 'target'
    $sch = Get-ConfigValue $Raw 'schedule'
    $ret = Get-ConfigValue $Raw 'retention'
    $rep = Get-ConfigValue $Raw 'report'
    $seen = @{}
    $folders = @()
    foreach ($f in @(Get-ConfigValue $Raw 'folders' @())) {
        $s = "$f".Trim()
        if (-not $s) { continue }
        $key = $s.TrimEnd('\').ToLower()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $folders += $s }
    }
    return [pscustomobject]@{
        Target = [pscustomobject]@{
            Type   = ("$(Get-ConfigValue $t 'type' '')").Trim().ToLower()
            Label  = ("$(Get-ConfigValue $t 'label' '')").Trim()
            Share  = ("$(Get-ConfigValue $t 'share' '')").Trim().TrimEnd('\')
            User   = ("$(Get-ConfigValue $t 'user' '')").Trim()
            Folder = ("$(Get-ConfigValue $t 'folder' 'WinResurectDaily')").Trim()
        }
        Folders       = $folders
        Excludes      = @(@(Get-ConfigValue $Raw 'excludes' @()) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        Time          = ("$(Get-ConfigValue $sch 'time' '12:30')").Trim()
        Retention     = [pscustomobject]@{
            Daily   = (ConvertTo-IntOrNull (Get-ConfigValue $ret 'daily' 14))
            Weekly  = (ConvertTo-IntOrNull (Get-ConfigValue $ret 'weekly' 8))
            Monthly = (ConvertTo-IntOrNull (Get-ConfigValue $ret 'monthly' 6))
        }
        ReportEnabled = [bool](Get-ConfigValue $rep 'enabled' $false)
    }
}

function Get-DailyTargetErrors {
    param([Parameter(Mandatory)]$Target)
    $e = @()
    if ($Target.Type -ne 'usb' -and $Target.Type -ne 'smb') { $e += "target.type musi być 'usb' albo 'smb'" }
    if ($Target.Folder -notmatch '^[A-Za-z0-9._-]+$' -or $Target.Folder -eq '.' -or $Target.Folder -eq '..') {
        $e += 'target.folder: dozwolone litery, cyfry, kropka, myślnik, podkreślnik (bez ..)'
    }
    if ($Target.Type -eq 'usb' -and $Target.Label -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,31}$') {
        $e += 'target.label: podaj etykietę dysku USB (litery, cyfry, spacja, . _ -, do 32 znaków)'
    }
    if ($Target.Type -eq 'smb') {
        if ($Target.Share -notmatch '^\\\\[^\\]+\\[^\\]+') { $e += 'target.share: podaj udział w postaci \\serwer\udział' }
        if (-not $Target.User) { $e += 'target.user: podaj użytkownika udziału' }
    }
    return $e
}

function Get-DailyConfigErrors {
    param([Parameter(Mandatory)]$Config)
    $e = @(Get-DailyTargetErrors -Target $Config.Target)
    if (@($Config.Folders).Count -eq 0) { $e += 'folders: lista nie może być pusta' }
    foreach ($f in @($Config.Folders)) {
        if ($f -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') { $e += "folders: ścieżka musi być bezwzględna (litera dysku lub UNC): '$f'" }
    }
    if ($Config.Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $e += "schedule.time: format GG:MM (otrzymano '$($Config.Time)')" }
    foreach ($k in 'Daily', 'Weekly', 'Monthly') {
        $v = $Config.Retention.$k
        if ($null -eq $v -or $v -lt 1) { $e += "retention.$($k.ToLower()): liczba całkowita >= 1" }
    }
    return $e
}

function Read-DailyConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Brak pliku konfiguracji: $Path" }
    try { $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "daily.json: niepoprawny JSON ($($_.Exception.Message))" }
    $cfg = ConvertTo-DailyConfig -Raw $raw
    $errs = @(Get-DailyConfigErrors -Config $cfg)
    if ($errs.Count -gt 0) { throw ('daily.json: ' + ($errs -join '; ')) }
    return $cfg
}

function Test-DailyTargetParams {
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Label = '',
        [string]$Share = '',
        [string]$User = '',
        [string]$Folder = 'WinResurectDaily'
    )
    $t = [pscustomobject]@{ Type = $Target.ToLower(); Label = $Label.Trim(); Share = $Share.Trim().TrimEnd('\'); User = $User.Trim(); Folder = $Folder.Trim() }
    $errs = @(Get-DailyTargetErrors -Target $t)
    if ($errs.Count -gt 0) { throw ($errs -join '; ') }
    return $t
}
