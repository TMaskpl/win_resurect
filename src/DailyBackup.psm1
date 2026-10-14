Set-StrictMode -Version Latest

function Get-ConfigValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function ConvertTo-ResticFolder {
    # Windows PowerShell 5.1 psuje argument z końcowym backslashem i spacją ("D:\Dane Firmy\"), więc go obcinamy (korzeń dysku zostaje).
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Trim()
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    return $p
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
        $s = ConvertTo-ResticFolder -Path $s
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
        elseif ($Target.User -match '[\x00-\x1f]') { $e += 'target.user: niedozwolone znaki sterujące' }
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
    $a += @($Folders | ForEach-Object { ConvertTo-ResticFolder -Path $_ })
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

function Expand-JsonItems {
    # Windows PowerShell 5.1 zwraca tablicę JSON jako jeden obiekt; PowerShell 7 wylicza elementy. Obsługujemy oba.
    param($Parsed)
    $out = @()
    foreach ($x in @($Parsed)) {
        if ($null -eq $x) { continue }
        if ($x -is [System.Array]) { foreach ($y in $x) { if ($null -ne $y) { $out += $y } } }
        else { $out += $x }
    }
    return $out
}

function ConvertFrom-ResticSnapshots {
    param([string]$Json)
    if (-not $Json -or -not $Json.Trim()) { return @() }
    try { $parsed = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return @() }
    $items = @(Expand-JsonItems -Parsed $parsed)
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
    try { $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
    if ($o -isnot [System.Management.Automation.PSCustomObject] -or -not $o.PSObject.Properties['status']) { return $null }
    return $o
}

function Get-DailyStaleness {
    param($LastRun, [Parameter(Mandatory)][datetime]$Now, [int]$MaxHours = 48)
    $v = Get-ConfigValue $LastRun 'last_success' ''
    if ($v -is [datetime]) { $t = $v }
    else {
        if (-not "$v") { return 'never' }
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { return 'never' }
    }
    if (($Now.ToUniversalTime() - $t.ToUniversalTime()).TotalHours -gt $MaxHours) { return 'stale' }
    return 'fresh'
}

function Get-DailyStatusText {
    param($LastRun, [Parameter(Mandatory)][datetime]$Now)
    if (-not $LastRun) { return 'Kopia codzienna: brak danych o przebiegach (jeszcze się nie wykonała).' }
    $stale = Get-DailyStaleness -LastRun $LastRun -Now $Now
    $ls = Get-ConfigValue $LastRun 'last_success' ''
    $lines = @(
        "Ostatni przebieg: $(Get-ConfigValue $LastRun 'status' '?') ($(Get-ConfigValue $LastRun 'finished' '?'))",
        "Ostatni sukces:   $(if ($ls) { $ls } else { 'brak' })",
        "Czas: $(Get-ConfigValue $LastRun 'duration_s' 0) s, dodano: $(Format-Size ([long](Get-ConfigValue $LastRun 'added_bytes' 0))), migawek: $(Get-ConfigValue $LastRun 'snapshots' 0)"
    )
    $note = Get-ConfigValue $LastRun 'note' ''
    if ($note) { $lines += "Uwagi: $note" }
    $sk = @(Get-ConfigValue $LastRun 'skipped_folders' @())
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
        [Parameter(Mandatory)][ValidateSet('backup', 'maintenance', 'init')][string]$Mode,
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
    try { Write-DailyLog -Path (Join-Path $WorkDir 'daily.log') -Lines @("$($started.ToString('yyyy-MM-dd HH:mm:ss')) Start ($Mode)") } catch { }
    $log = New-Object System.Collections.ArrayList
    $secrets = New-Object System.Collections.ArrayList
    $say = { param($m) [void]$log.Add((Hide-Secrets -Text $m -Secrets @($secrets))) }
    $lastName = switch ($Mode) { 'backup' { 'last-run.json' } 'maintenance' { 'last-maintenance.json' } default { 'last-init.json' } }
    $lastPath = Join-Path $WorkDir $lastName
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
            if ($Mode -eq 'backup') {
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
            elseif ($Mode -eq 'maintenance') {
                $steps = @((Get-DailyForgetArgs -Config $Config -ComputerName $ComputerName), (Get-DailyCheckArgs))
                foreach ($argList in $steps) {
                    try { $r = & $Runner 'restic' $argList }
                    catch { $r = @{ ExitCode = -1; Output = @($_.Exception.Message) } }
                    $stepStatus = ConvertTo-DailyStatus -ExitCode $r.ExitCode
                    if ($stepStatus -ne 'ok' -and -not $note) { $note = Get-FailureNote -Lines $r.Output }
                    $status = Get-WorseStatus -A $status -B $stepStatus
                }
            }
            else {
                try { $r = & $Runner 'restic' (Get-DailyInitCheckArgs) } catch { $r = @{ ExitCode = -1; Output = @($_.Exception.Message) } }
                if ($r.ExitCode -ne 0) {
                    try { $r = & $Runner 'restic' @('init') } catch { $r = @{ ExitCode = -1; Output = @($_.Exception.Message) } }
                    $status = ConvertTo-DailyStatus -ExitCode $r.ExitCode
                    if ($status -ne 'ok') { $note = Get-FailureNote -Lines $r.Output }
                }
            }
        }
    }
    catch {
        $status = 'fail'
        $note = "nieoczekiwany błąd: $($_.Exception.Message)"
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
    & $say "Kopia codzienna ($Mode): $status$(if ($lr.note) { ' - ' + $lr.note })"
    Write-DailyLog -Path (Join-Path $WorkDir 'daily.log') -Lines (@($log) | ForEach-Object { "$($started.ToString('yyyy-MM-dd HH:mm:ss')) $_" })
    return [pscustomobject]@{ ExitCode = $(if ($status -eq 'fail') { 1 } else { 0 }); Status = $status; LastRun = [pscustomobject]$lr }
}

function Get-DailyTaskSpecs {
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$Time,
        [string]$MaintenanceDay = 'Sunday',
        [string]$MaintenanceTime = '20:00'
    )
    $script = '{0}\Run-DailyBackup.ps1' -f $InstallDir.TrimEnd('\')
    $base = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script
    return @(
        [pscustomobject]@{
            Name = 'WinResurect-Daily'; Execute = 'powershell.exe'; Arguments = "$base -Mode backup"
            TriggerType = 'Daily'; At = $Time; DaysOfWeek = ''
            StartWhenAvailable = $true; RestartCount = 2; RestartIntervalMinutes = 30
            ExecutionTimeLimitHours = 6; AllowStartIfOnBatteries = $false; MultipleInstances = 'IgnoreNew'
        },
        [pscustomobject]@{
            Name = 'WinResurect-Maintenance'; Execute = 'powershell.exe'; Arguments = "$base -Mode maintenance"
            TriggerType = 'Weekly'; At = $MaintenanceTime; DaysOfWeek = $MaintenanceDay
            StartWhenAvailable = $true; RestartCount = 0; RestartIntervalMinutes = 0
            ExecutionTimeLimitHours = 6; AllowStartIfOnBatteries = $false; MultipleInstances = 'IgnoreNew'
        }
    )
}

function Register-DailyTasks {
    # Tylko Windows.
    param([Parameter(Mandatory)][object[]]$Specs)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    foreach ($s in $Specs) {
        $action = New-ScheduledTaskAction -Execute $s.Execute -Argument $s.Arguments
        if ($s.TriggerType -eq 'Daily') { $trigger = New-ScheduledTaskTrigger -Daily -At $s.At }
        else { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $s.DaysOfWeek -At $s.At }
        $opts = @{ StartWhenAvailable = $true; ExecutionTimeLimit = (New-TimeSpan -Hours $s.ExecutionTimeLimitHours); MultipleInstances = $s.MultipleInstances }
        if ($s.AllowStartIfOnBatteries) { $opts['AllowStartIfOnBatteries'] = $true }
        if ($s.RestartCount -gt 0) { $opts['RestartCount'] = $s.RestartCount; $opts['RestartInterval'] = (New-TimeSpan -Minutes $s.RestartIntervalMinutes) }
        $settings = New-ScheduledTaskSettingsSet @opts
        Register-ScheduledTask -TaskName $s.Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    }
}

function Unregister-DailyTasks {
    # Tylko Windows.
    foreach ($n in 'WinResurect-Daily', 'WinResurect-Maintenance') {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Get-DailyHome {
    if ($env:WINRES_HOME) { return $env:WINRES_HOME }
    $pd = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    return ('{0}\WinResurect' -f $pd.TrimEnd('\'))
}

function Get-RestoreArgs {
    param([Parameter(Mandatory)][string]$SnapshotId, [Parameter(Mandatory)][string]$Target, [string[]]$Include = @())
    $a = @('restore', $SnapshotId, '--target', $Target)
    foreach ($i in $Include) { $a += @('--include', $i) }
    return $a
}

function Test-RestoreTargetSafe {
    param([string]$Target, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Folders)
    if (-not $Target -or -not $Target.Trim()) { return $false }
    $t = $Target.Trim().TrimEnd('\').ToLower()
    if ($t -match '^[a-z]:$') { return $false }
    foreach ($f in $Folders) {
        $x = $f.Trim().TrimEnd('\').ToLower()
        if ($t -eq $x -or $t.StartsWith($x + '\') -or $x.StartsWith($t + '\')) { return $false }
    }
    return $true
}

function New-RestoreTarget {
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][datetime]$Now)
    return ('{0}\Przywrocone_{1}' -f $Base.TrimEnd('\'), $Now.ToString('yyyy-MM-dd_HHmm', [System.Globalization.CultureInfo]::InvariantCulture))
}

function Get-ResticVersionSpec {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Brak pliku z wersją restic: $Path" }
    try { $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'restic-version.json: niepoprawny JSON' }
    $v = [string](Get-ConfigValue $j 'version' '')
    $u = [string](Get-ConfigValue $j 'url' '')
    $h = [string](Get-ConfigValue $j 'sha256' '')
    if ($v -notmatch '^\d+\.\d+\.\d+$') { throw 'restic-version.json: niepoprawna wersja' }
    if ($u -notmatch '^https://github\.com/restic/restic/releases/download/') { throw 'restic-version.json: adres musi wskazywać oficjalne wydanie restic na GitHubie' }
    if ($h -notmatch '^[0-9a-fA-F]{64}$') { throw 'restic-version.json: suma SHA256 musi mieć 64 znaki szesnastkowe' }
    return [pscustomobject]@{ Version = $v; Url = $u; Sha256 = $h.ToLower() }
}

function Test-FileSha256 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower() -eq $Expected.Trim().ToLower())
}

function New-RandomPassword {
    param([int]$Length = 32)
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $limit = [uint32]([Math]::Floor(4294967296 / $chars.Length) * $chars.Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 4
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Length; $i++) {
        do { $rng.GetBytes($bytes); $v = [BitConverter]::ToUInt32($bytes, 0) } while ($v -ge $limit)
        [void]$sb.Append($chars[[int]($v % $chars.Length)])
    }
    return $sb.ToString()
}

function Set-RestrictedAcl {
    # Tylko Windows: SYSTEM i Administratorzy, bez dziedziczenia.
    param([Parameter(Mandatory)][string]$Path)
    $isDir = (Get-Item -LiteralPath $Path).PSIsContainer
    $acl = if ($isDir) { New-Object System.Security.AccessControl.DirectorySecurity } else { New-Object System.Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    try { $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544'))) } catch { }
    $inherit = if ($isDir) { 'ContainerInherit,ObjectInherit' } else { 'None' }
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inherit, 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function New-DailyConfigJson {
    param(
        [Parameter(Mandatory)][string]$Type, [string]$Label = '', [string]$Share = '', [string]$User = '',
        [string]$Folder = 'WinResurectDaily', [string]$Time = '12:30', [string[]]$Folders = @()
    )
    $target = [ordered]@{ type = $Type }
    if ($Type -eq 'usb') { $target['label'] = $Label } else { $target['share'] = $Share; $target['user'] = $User }
    $target['folder'] = $Folder
    $cfg = [ordered]@{
        target = $target; folders = @($Folders); excludes = @('*.tmp', 'Thumbs.db', 'node_modules')
        schedule = [ordered]@{ time = $Time }; retention = [ordered]@{ daily = 14; weekly = 8; monthly = 6 }
        report = [ordered]@{ enabled = $false }
    }
    return ($cfg | ConvertTo-Json -Depth 6)
}

function Update-DailyConfigJson {
    param(
        [Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Type, [string]$Label = '',
        [string]$Share = '', [string]$User = '', [string]$Folder = '', [string]$Time = ''
    )
    $o = $Json | ConvertFrom-Json
    $oldFolder = [string](Get-ConfigValue (Get-ConfigValue $o 'target') 'folder' '')
    $oldTime = [string](Get-ConfigValue (Get-ConfigValue $o 'schedule') 'time' '')
    $f = if ($Folder) { $Folder } elseif ($oldFolder) { $oldFolder } else { 'WinResurectDaily' }
    $tm = if ($Time) { $Time } elseif ($oldTime) { $oldTime } else { '12:30' }
    $target = [ordered]@{ type = $Type }
    if ($Type -eq 'usb') { $target['label'] = $Label } else { $target['share'] = $Share; $target['user'] = $User }
    $target['folder'] = $f
    $o | Add-Member -NotePropertyName target -NotePropertyValue ([pscustomobject]$target) -Force
    $o | Add-Member -NotePropertyName schedule -NotePropertyValue ([pscustomobject]@{ time = $tm }) -Force
    return ($o | ConvertTo-Json -Depth 6)
}

function ConvertTo-SingleQuoted {
    # Bezpieczny literał PowerShell w apostrofach (podwaja także typograficzne apostrofy, które parser traktuje jak apostrof).
    param([string]$Text)
    return "'" + [regex]::Replace($Text, "['\u2018\u2019\u201A\u201B]", '$0$0') + "'"
}

function Get-SetCredScript {
    param([Parameter(Mandatory)][string]$TmpPath, [Parameter(Mandatory)][string]$CredPath, [Parameter(Mandatory)][string]$User)
    $lines = @(
        "`$ErrorActionPreference = 'Stop'",
        ('$p = [System.IO.File]::ReadAllText({0}, [System.Text.Encoding]::UTF8)' -f (ConvertTo-SingleQuoted $TmpPath)),
        '$sec = ConvertTo-SecureString $p -AsPlainText -Force',
        ('Set-Content -LiteralPath {0} -Value @({1}, (ConvertFrom-SecureString $sec)) -Encoding UTF8' -f (ConvertTo-SingleQuoted $CredPath), (ConvertTo-SingleQuoted $User)),
        ('Remove-Item -LiteralPath {0} -Force' -f (ConvertTo-SingleQuoted $TmpPath))
    )
    return ($lines -join "`r`n")
}

function Get-AsSystemArgument {
    # Harmonogram nie używa powłoki, więc przekierowanie `*>` działa tylko wewnątrz -Command.
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string]$Log)
    $cmd = '& {0} *> {1}; exit $LASTEXITCODE' -f (ConvertTo-SingleQuoted $Script), (ConvertTo-SingleQuoted $Log)
    return ('-NoProfile -ExecutionPolicy Bypass -Command "{0}"' -f $cmd)
}

function Test-TrustedOwnerSid {
    param([string]$Sid)
    return (@('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') -contains $Sid)
}

function Get-ResticExeName {
    param([Parameter(Mandatory)][string]$Version)
    return ('restic_{0}_windows_amd64.exe' -f $Version)
}

function Get-InstallPreflightErrors {
    param([bool]$IsAdmin = $true, [bool]$Is64Bit = $true, [bool]$TargetOk = $true, [string]$TargetReason = '', [bool]$WorkDirTrusted = $true, [string]$WorkDir = '')
    $e = @()
    if (-not $IsAdmin) { $e += 'Uruchom jako administrator (Start.cmd robi to automatycznie).' }
    if (-not $Is64Bit) { $e += 'Wymagany system 64-bitowy (restic jest dostarczany tylko w wersji amd64).' }
    if (-not $TargetOk) { $e += "Cel kopii niedostępny: $TargetReason" }
    if (-not $WorkDirTrusted) { $e += "Katalog $WorkDir istnieje i nie należy do SYSTEM ani Administratorów. Usuń go albo przejmij własność i uruchom instalację ponownie." }
    return $e
}

function Select-SafeRestoreBase {
    param([string[]]$Candidates, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Folders, [Parameter(Mandatory)][datetime]$Now)
    foreach ($c in $Candidates) {
        if (-not $c) { continue }
        $t = New-RestoreTarget -Base $c -Now $Now
        if (Test-RestoreTargetSafe -Target $t -Folders $Folders) { return $c }
    }
    return $null
}

function Invoke-AsSystem {
    # Tylko Windows: jednorazowe zadanie jako SYSTEM; skrypt w pliku z ograniczonym ACL, wynik w logu.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ScriptText, [Parameter(Mandatory)][string]$WorkDir, [int]$TimeoutSec = 600)
    $script = '{0}\{1}.ps1' -f $WorkDir, $Name
    $log = '{0}\{1}.log' -f $WorkDir, $Name
    Set-Content -LiteralPath $script -Value $ScriptText -Encoding UTF8
    Set-RestrictedAcl -Path $script
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-AsSystemArgument -Script $script -Log $log)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $Name -Action $action -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $Name
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        do { Start-Sleep -Seconds 2; $state = (Get-ScheduledTask -TaskName $Name).State } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
        return (Get-ScheduledTaskInfo -TaskName $Name).LastTaskResult
    }
    finally {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    }
}
