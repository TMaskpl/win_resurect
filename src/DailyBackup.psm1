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

function Resolve-DailyTarget {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Volumes,
        [Parameter(Mandatory)][string]$ComputerName
    )
    $t = $Config.Target
    if ($t.Type -eq 'smb') {
        return [pscustomobject]@{
            Ok = $true; Reason = ''; Drive = ''
            ShareRoot  = Get-ShareRoot -Share $t.Share
            Repository = '{0}\{1}\{2}' -f $t.Share, $t.Folder, $ComputerName
        }
    }
    $found = @($Volumes | Where-Object { $_.Label -eq $t.Label })
    if ($found.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = "cel niedostępny: nie znaleziono dysku o etykiecie '$($t.Label)'"; Drive = ''; ShareRoot = ''; Repository = '' }
    }
    if ($found.Count -gt 1) {
        return [pscustomobject]@{ Ok = $false; Reason = "więcej niż jeden dysk o etykiecie '$($t.Label)' - nadaj unikalną etykietę"; Drive = ''; ShareRoot = ''; Repository = '' }
    }
    $drive = $found[0].Drive.Substring(0, 1).ToUpper() + ':'
    return [pscustomobject]@{ Ok = $true; Reason = ''; Drive = $drive; ShareRoot = ''; Repository = '{0}\{1}\{2}' -f $drive, $t.Folder, $ComputerName }
}

function Get-DailyBackupArgs {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Folders, [Parameter(Mandatory)][string]$ComputerName)
    $a = @('backup', '--json', '--use-fs-snapshot', '--host', $ComputerName)
    foreach ($e in @($Config.Excludes)) { $a += @('--exclude', $e) }
    $a += @($Folders)
    return $a
}

function Get-DailyForgetArgs {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ComputerName)
    return @('forget', '--host', $ComputerName, '--keep-daily', [string]$Config.Retention.Daily,
        '--keep-weekly', [string]$Config.Retention.Weekly, '--keep-monthly', [string]$Config.Retention.Monthly, '--prune')
}

function Get-DailyCheckArgs { return @('check', '--read-data-subset=5%') }

function Get-DailyInitCheckArgs { return @('cat', 'config') }

function ConvertTo-DailyStatus {
    param([Parameter(Mandatory)][int]$ExitCode)
    if ($ExitCode -eq 0) { return 'ok' }
    if ($ExitCode -eq 3) { return 'warn' }
    return 'fail'
}

function Get-WorseStatus {
    param([string]$A, [string]$B)
    $rank = @{ ok = 0; warn = 1; fail = 2 }
    if ($rank[$B] -gt $rank[$A]) { return $B }
    return $A
}

function ConvertFrom-ResticSummary {
    param([string[]]$Lines)
    $added = [long]0
    $snap = ''
    foreach ($line in $Lines) {
        if (-not $line -or -not $line.TrimStart().StartsWith('{')) { continue }
        try { $j = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $mt = $j.PSObject.Properties['message_type']
        if ($mt -and $mt.Value -eq 'summary') {
            $added = [long](Get-ConfigValue $j 'data_added' 0)
            $id = [string](Get-ConfigValue $j 'snapshot_id' '')
            $snap = $id.Substring(0, [Math]::Min(8, $id.Length))
        }
    }
    return @{ AddedBytes = $added; Snapshot = $snap }
}

function ConvertFrom-ResticSnapshots {
    param([string]$Json)
    if (-not $Json -or -not $Json.Trim()) { return @() }
    try { $items = @($Json | ConvertFrom-Json -ErrorAction Stop) } catch { return @() }
    $out = @()
    foreach ($i in $items) {
        $raw = [string](Get-ConfigValue $i 'time' '')
        $trimmed = $raw -replace '(\.\d{7})\d+', '$1'
        $time = [datetime]::MinValue
        [void][datetime]::TryParse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$time)
        $out += [pscustomobject]@{
            Id = [string](Get-ConfigValue $i 'id' ''); ShortId = [string](Get-ConfigValue $i 'short_id' '')
            Time = $time; Host = [string](Get-ConfigValue $i 'hostname' ''); Paths = @(Get-ConfigValue $i 'paths' @())
        }
    }
    return $out
}

function Format-Note {
    param([string]$Text, [int]$MaxLength = 200)
    if (-not $Text) { return '' }
    $t = $Text -replace '[\x00-\x1f\x7f-\x9f]', ' '
    $t = $t -replace '\\\\[^\s"'']+', '<path>'
    $t = $t -replace '[A-Za-z]:\\[^\s"'']*', '<path>'
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength) }
    return $t
}

function Get-FailureNote {
    param([string[]]$Lines)
    $picked = @()
    foreach ($line in $Lines) {
        if (-not $line -or -not $line.Trim()) { continue }
        if ($line.TrimStart().StartsWith('{')) {
            try { $j = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $mt = $j.PSObject.Properties['message_type']
            if ($mt -and $mt.Value -eq 'error') {
                $err = $j.PSObject.Properties['error']
                $msg = if ($err -and $err.Value.PSObject.Properties['message']) { [string]$err.Value.message } else { 'error' }
                $picked += $msg
            }
        }
        else { $picked += $line.Trim() }
    }
    return Format-Note -Text (@($picked | Select-Object -Last 3) -join ' | ')
}

function Select-ExistingFolders {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Folders,
        [scriptblock]$Exists = { param($p) Test-Path -LiteralPath $p }
    )
    $ok = @(); $missing = @()
    foreach ($f in $Folders) { if (& $Exists $f) { $ok += $f } else { $missing += $f } }
    return @{ Existing = $ok; Missing = $missing }
}

function New-LastRun {
    param(
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'fail')][string]$Status,
        [Parameter(Mandatory)][datetime]$Started,
        [Parameter(Mandatory)][datetime]$Finished,
        [long]$AddedBytes = 0,
        [string]$Snapshot = '',
        [int]$Snapshots = 0,
        [string]$ResticVersion = '',
        [string[]]$Skipped = @(),
        [string]$Note = '',
        $Previous = $null
    )
    $fmt = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    $fin = $Finished.ToUniversalTime().ToString($fmt)
    $lastSuccess = ''
    if ($Status -eq 'ok' -or $Status -eq 'warn') { $lastSuccess = $fin }
    elseif ($Previous -and $Previous.PSObject.Properties['last_success']) { $lastSuccess = [string]$Previous.last_success }
    return [ordered]@{
        status = $Status; started = $Started.ToUniversalTime().ToString($fmt); finished = $fin
        duration_s = [int][Math]::Round(($Finished - $Started).TotalSeconds)
        added_bytes = $AddedBytes; snapshot = $Snapshot; snapshots = $Snapshots; restic_version = $ResticVersion
        skipped_folders = @($Skipped); note = (Format-Note -Text $Note); last_success = $lastSuccess
    }
}

function Save-LastRun {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$LastRun)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $LastRun | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-LastRun {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function Get-DailyStaleness {
    param($LastRun, [Parameter(Mandatory)][datetime]$Now, [int]$MaxHours = 48)
    if (-not $LastRun -or -not $LastRun.PSObject.Properties['last_success'] -or -not $LastRun.last_success) { return 'never' }
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$LastRun.last_success, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { return 'never' }
    if (($Now.ToUniversalTime() - $t.ToUniversalTime()).TotalHours -gt $MaxHours) { return 'stale' }
    return 'fresh'
}

function Get-DailyStatusText {
    param($LastRun, [Parameter(Mandatory)][datetime]$Now)
    if (-not $LastRun) { return 'Kopia codzienna: brak danych o przebiegach (jeszcze się nie wykonała).' }
    $stale = Get-DailyStaleness -LastRun $LastRun -Now $Now
    $lines = @(
        "Ostatni przebieg: $($LastRun.status) ($($LastRun.finished))",
        "Ostatni sukces:   $(if ($LastRun.last_success) { $LastRun.last_success } else { 'brak' })",
        "Czas: $($LastRun.duration_s) s, dodano: $(Format-Size ([long]$LastRun.added_bytes)), migawek: $($LastRun.snapshots)"
    )
    if ($LastRun.note) { $lines += "Uwagi: $($LastRun.note)" }
    $sk = @($LastRun.skipped_folders)
    if ($sk.Count -gt 0) { $lines += "Pominięte foldery: $($sk -join ', ')" }
    if ($stale -eq 'stale') { $lines += 'UWAGA: kopia NIEAKTUALNA (ostatni sukces starszy niż 48 godzin).' }
    elseif ($stale -eq 'never') { $lines += 'UWAGA: kopia NIEAKTUALNA (brak udanego przebiegu).' }
    return ($lines -join "`r`n")
}

function Write-DailyLog {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Lines, [int]$MaxBytes = 1048576, [int]$Keep = 5)
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -ge $MaxBytes)) {
        $last = "$Path.$($Keep - 1)"
        if (Test-Path -LiteralPath $last) { Remove-Item -LiteralPath $last -Force }
        for ($i = $Keep - 2; $i -ge 1; $i--) {
            if (Test-Path -LiteralPath "$Path.$i") { Move-Item -LiteralPath "$Path.$i" -Destination "$Path.$($i + 1)" -Force }
        }
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }
    Add-Content -LiteralPath $Path -Value $Lines -Encoding UTF8
}

function Invoke-DailyJob {
    param(
        [Parameter(Mandatory)][ValidateSet('backup')][string]$Mode,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Volumes,
        [Parameter(Mandatory)][scriptblock]$Runner,
        [Parameter(Mandatory)][string]$WorkDir,
        [scriptblock]$ReadSmbCredential = { $null },
        [scriptblock]$Connector = { param($Share, $User, $Password) Connect-NetworkShare -Share $Share -User $User -Password $Password },
        [scriptblock]$Disconnector = { param($Share) Disconnect-NetworkShare -Share $Share },
        [scriptblock]$PathExists = { param($Path) Test-Path -LiteralPath $Path },
        [scriptblock]$Clock = { Get-Date },
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$ResticVersion = ''
    )
    $started = & $Clock
    $log = New-Object System.Collections.ArrayList
    $secrets = New-Object System.Collections.ArrayList
    $say = { param($m) [void]$log.Add((Hide-Secrets -Text $m -Secrets @($secrets))) }
    $lastPath = Join-Path $WorkDir 'last-run.json'
    $previous = Read-LastRun -Path $lastPath
    $status = 'ok'; $note = ''; $added = [long]0; $snap = ''; $count = 0; $skipped = @()
    $connected = $false; $shareRoot = ''
    $oldRepo = $env:RESTIC_REPOSITORY; $oldPass = $env:RESTIC_PASSWORD_FILE
    try {
        $target = Resolve-DailyTarget -Config $Config -Volumes $Volumes -ComputerName $ComputerName
        if (-not $target.Ok) { $status = 'fail'; $note = $target.Reason }
        if ($status -ne 'fail' -and $Config.Target.Type -eq 'smb') {
            $cred = & $ReadSmbCredential
            if (-not $cred) { $status = 'fail'; $note = 'brak poświadczeń SMB (uruchom instalację ponownie)' }
            else {
                $plain = $cred.GetNetworkCredential().Password
                [void]$secrets.Add($plain)
                $c = & $Connector $target.ShareRoot $Config.Target.User $plain
                if ($c.ExitCode -ne 0) { $status = 'fail'; $note = "nie można połączyć się z udziałem (kod $($c.ExitCode)): $(@($c.Output) -join ' ')" }
                else { $connected = $true; $shareRoot = $target.ShareRoot }
            }
        }
        if ($status -ne 'fail') {
            $env:RESTIC_REPOSITORY = $target.Repository
            $env:RESTIC_PASSWORD_FILE = Join-Path $WorkDir 'repo.pass'
            $split = Select-ExistingFolders -Folders @($Config.Folders) -Exists $PathExists
            $skipped = @($split.Missing)
            foreach ($m in $skipped) { & $say "Ostrzeżenie: folder nie istnieje, pominięto: $m" }
            if (@($split.Existing).Count -eq 0) { $status = 'fail'; $note = 'żaden folder z listy nie istnieje' }
            else {
                try { [void](& $Runner 'restic' @('unlock')) } catch { }
                try { $r = & $Runner 'restic' (Get-DailyBackupArgs -Config $Config -Folders @($split.Existing) -ComputerName $ComputerName) }
                catch { $r = @{ ExitCode = -1; Output = @($_.Exception.Message) } }
                $status = ConvertTo-DailyStatus -ExitCode $r.ExitCode
                $sum = ConvertFrom-ResticSummary -Lines $r.Output
                $added = $sum.AddedBytes; $snap = $sum.Snapshot
                if ($status -ne 'ok') { $note = Get-FailureNote -Lines $r.Output }
                if ($status -ne 'fail') {
                    try {
                        $s = & $Runner 'restic' @('snapshots', '--json', '--host', $ComputerName)
                        $count = @(ConvertFrom-ResticSnapshots -Json (@($s.Output) -join "`n")).Count
                    }
                    catch { }
                    if ($skipped.Count -gt 0) {
                        $status = Get-WorseStatus -A $status -B 'warn'
                        if (-not $note) { $note = "pominięto $($skipped.Count) nieistniejących folderów" }
                    }
                }
            }
        }
    }
    finally {
        if ($null -eq $oldRepo) { Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue } else { $env:RESTIC_REPOSITORY = $oldRepo }
        if ($null -eq $oldPass) { Remove-Item Env:RESTIC_PASSWORD_FILE -ErrorAction SilentlyContinue } else { $env:RESTIC_PASSWORD_FILE = $oldPass }
        if ($connected) { try { [void](& $Disconnector $shareRoot) } catch { } }
    }
    $finished = & $Clock
    $lr = New-LastRun -Status $status -Started $started -Finished $finished -AddedBytes $added -Snapshot $snap -Snapshots $count `
        -ResticVersion $ResticVersion -Skipped $skipped -Note (Hide-Secrets -Text $note -Secrets @($secrets)) -Previous $previous
    Save-LastRun -Path $lastPath -LastRun $lr
    & $say "Kopia codzienna: $status$(if ($lr.note) { ' - ' + $lr.note })"
    Write-DailyLog -Path (Join-Path $WorkDir 'daily.log') -Lines (@($log) | ForEach-Object { "$($started.ToString('yyyy-MM-dd HH:mm:ss')) $_" })
    return [pscustomobject]@{ ExitCode = $(if ($status -eq 'fail') { 1 } else { 0 }); Status = $status; LastRun = [pscustomobject]$lr }
}
