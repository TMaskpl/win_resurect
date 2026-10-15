Set-StrictMode -Version Latest

function Get-RepairThresholds {
    return [pscustomobject]@{
        FreePctWarn = 15; FreePctBad = 5
        SsdWearWarn = 80
        BootWarnSec = 90; BootBadSec = 180
        UpdateWarnDays = 60
        RamWarnGB = 8; RamUsedWarnPct = 85
        CrashBad = 2
    }
}

function New-Finding {
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'bad', 'nodata')][string]$Status,
        [Parameter(Mandatory)][string]$Summary,
        [string]$Detail = ''
    )
    return [pscustomobject]@{ group = $Group; status = $Status; summary = $Summary; detail = $Detail }
}

function Get-WorstAuditStatus {
    param([AllowEmptyCollection()][string[]]$Statuses = @())
    $rank = @{ nodata = 0; ok = 1; warn = 2; bad = 3 }
    $best = 'nodata'
    foreach ($s in $Statuses) { if ($rank[$s] -gt $rank[$best]) { $best = $s } }
    return $best
}

function Get-SpaceStatus {
    param([Parameter(Mandatory)][long]$FreeBytes, [Parameter(Mandatory)][long]$TotalBytes)
    if ($TotalBytes -le 0) { return 'nodata' }
    $t = Get-RepairThresholds
    $pct = 100.0 * $FreeBytes / $TotalBytes
    if ($pct -lt $t.FreePctBad) { return 'bad' }
    if ($pct -lt $t.FreePctWarn) { return 'warn' }
    return 'ok'
}

function Get-BootStatus {
    param([AllowEmptyCollection()][double[]]$Seconds = @())
    if (@($Seconds).Count -eq 0) { return 'nodata' }
    $t = Get-RepairThresholds
    $avg = (@($Seconds) | Measure-Object -Average).Average
    if ($avg -gt $t.BootBadSec) { return 'bad' }
    if ($avg -gt $t.BootWarnSec) { return 'warn' }
    return 'ok'
}

function Get-DiskHealthStatus {
    param([AllowEmptyCollection()][object[]]$Disks = @())
    if (@($Disks).Count -eq 0) { return 'nodata' }
    $t = Get-RepairThresholds
    $all = @()
    foreach ($d in $Disks) {
        $s = 'ok'
        if ($d.Health -eq 'Unhealthy' -or ($null -ne $d.Unreadable -and [long]$d.Unreadable -gt 0)) { $s = 'bad' }
        elseif ($d.Health -ne 'Healthy' -or ($null -ne $d.Wear -and [int]$d.Wear -gt $t.SsdWearWarn)) { $s = 'warn' }
        $all += $s
    }
    return (Get-WorstAuditStatus -Statuses $all)
}

function Get-UpdateStatus {
    param(
        [hashtable]$StartTypes = @{},
        [Nullable[int]]$DaysSinceInstall = $null,
        [bool]$PendingReboot = $false,
        [string]$RepeatedErrorCode = $null
    )
    $t = Get-RepairThresholds
    if (@($StartTypes.Values | Where-Object { $_ -eq 'Disabled' }).Count -gt 0) { return 'bad' }
    if ($RepeatedErrorCode) { return 'bad' }
    if ($PendingReboot) { return 'warn' }
    if ($null -eq $DaysSinceInstall) { return 'nodata' }
    if ($DaysSinceInstall -gt $t.UpdateWarnDays) { return 'warn' }
    return 'ok'
}

function Get-MemoryStatus {
    param([Parameter(Mandatory)][double]$TotalGB, [Parameter(Mandatory)][double]$UsedPct, [Parameter(Mandatory)][int]$CrashCount)
    $t = Get-RepairThresholds
    if ($CrashCount -ge $t.CrashBad) { return 'bad' }
    if ($CrashCount -ge 1 -or $TotalGB -lt $t.RamWarnGB -or $UsedPct -gt $t.RamUsedWarnPct) { return 'warn' }
    return 'ok'
}

function Get-IntegrityStatus {
    param([Parameter(Mandatory)][string]$Dism, [Parameter(Mandatory)][int]$SfcUnrepaired)
    if ($Dism -in 'repairable', 'notrepairable' -or $SfcUnrepaired -gt 0) { return 'bad' }
    if ($Dism -eq 'healthy') { return 'ok' }
    return 'nodata'
}

function ConvertFrom-DismCheckHealth {
    param([AllowEmptyString()][string]$Text = '')
    if (-not $Text) { return 'unknown' }
    $t = $Text -replace "`0", ''
    if ($t -match '(?i)not repairable|nie (mo[żz]na|da si[ęe]) naprawi') { return 'notrepairable' }
    if ($t -match '(?i)is repairable|mo[żz]na naprawi') { return 'repairable' }
    if ($t -match '(?i)No component store corruption detected|Nie wykryto uszkodze') { return 'healthy' }
    return 'unknown'
}

function ConvertFrom-AnalyzeComponentStore {
    param([AllowEmptyString()][string]$Text = '')
    $t = $Text -replace "`0", ''
    if ($t -match '(?im)(Cleanup Recommended|Zalecane czyszczenie[^:\r\n]*)\s*:\s*(Yes|Tak|No|Nie)\s*$') {
        return ($Matches[2] -in 'Yes', 'Tak')
    }
    return $null
}

function Get-SfcLogSummary {
    param([AllowEmptyCollection()][string[]]$Lines = @())
    $start = -1
    for ($i = 0; $i -lt @($Lines).Count; $i++) { if ($Lines[$i] -match '\[SR\] Beginning') { $start = $i } }
    $n = 0
    if ($start -ge 0) {
        for ($i = $start; $i -lt @($Lines).Count; $i++) { if ($Lines[$i] -match '\[SR\] Cannot repair member file') { $n++ } }
    }
    return @{ Unrepaired = $n }
}

function Get-CandidateLabel {
    param([string]$Id)
    $l = @{
        'temp-user' = 'Pliki tymczasowe użytkowników'; 'temp-win' = 'Pliki tymczasowe systemu'
        'wu-download' = 'Pobrane aktualizacje (cache Windows Update)'; 'dumps' = 'Zrzuty awaryjne'
        'recycle' = 'Kosz'; 'hibernate' = 'Plik hibernacji (hiberfil.sys)'
    }
    if ($l.ContainsKey($Id)) { return $l[$Id] }
    return $Id
}

function Get-CleanupCandidates {
    param([Parameter(Mandatory)]$Sizes)
    $out = @()
    foreach ($k in $Sizes.Keys) {
        if ([long]$Sizes[$k] -gt 0) { $out += [pscustomobject]@{ id = [string]$k; label = (Get-CandidateLabel -Id $k); bytes = [long]$Sizes[$k] } }
    }
    return @($out | Sort-Object -Property bytes -Descending)
}

function Get-FindingSummary {
    param([Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Status)
    $s = @{
        'disk.ok' = 'Dyski fizyczne zgłaszają dobry stan.'
        'disk.warn' = 'Dysk zgłasza ostrzeżenie lub duże zużycie.'
        'disk.bad' = 'Dysk zgłasza awarię lub błędy odczytu: rozważ wymianę.'
        'space.ok' = 'Wolnego miejsca jest wystarczająco.'
        'space.warn' = 'Mało wolnego miejsca (poniżej 15%).'
        'space.bad' = 'Krytycznie mało wolnego miejsca (poniżej 5%).'
        'boot.ok' = 'Czas startu systemu w normie.'
        'boot.warn' = 'Start systemu jest wolny (średnio ponad 90 s).'
        'boot.bad' = 'Start systemu jest bardzo wolny (średnio ponad 180 s).'
        'integrity.ok' = 'Pliki systemowe bez uszkodzeń.'
        'integrity.warn' = 'Integralność systemu wymaga sprawdzenia.'
        'integrity.bad' = 'Wykryto uszkodzenia plików systemowych.'
        'updates.ok' = 'Windows Update działa i jest aktualny.'
        'updates.warn' = 'Aktualizacje wymagają uwagi (stare lub oczekuje restart).'
        'updates.bad' = 'Windows Update nie działa poprawnie (usługa wyłączona lub powtarzający się błąd).'
        'memory.ok' = 'Pamięć i stabilność w normie.'
        'memory.warn' = 'Mało lub dużo zajętej pamięci albo pojedynczy restart awaryjny.'
        'memory.bad' = 'Powtarzające się restarty awaryjne (co najmniej 2 w 30 dni).'
    }
    $key = '{0}.{1}' -f $Group, $Status
    if ($s.ContainsKey($key)) { return $s[$key] }
    return 'Brak danych.'
}

function Get-GroupTitle {
    param([string]$Group)
    $t = @{ disk = 'Dysk fizyczny'; space = 'Miejsce na dysku'; boot = 'Start systemu'; integrity = 'Integralność systemu'; updates = 'Aktualizacje'; memory = 'Pamięć i stabilność' }
    if ($t.ContainsKey($Group)) { return $t[$Group] }
    return $Group
}

function Get-StatusLabel {
    param([string]$Status)
    switch ($Status) { 'ok' { return 'OK' } 'warn' { return 'UWAGA' } 'bad' { return 'ZŁY' } default { return 'BRAK DANYCH' } }
}

function Get-AuditMetric {
    param($Audit, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Audit) { return $null }
    $m = $Audit.metrics
    if ($null -eq $m) { return $null }
    if ($m -is [System.Collections.IDictionary]) { if ($m.Contains($Name)) { return $m[$Name] } return $null }
    $p = $m.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Format-AuditReport {
    param([Parameter(Mandatory)]$Audit)
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add(('Raport systemu: {0}  ({1})' -f $Audit.computer, $Audit.generated))
    [void]$L.Add('')
    [void]$L.Add('WNIOSKI')
    $findings = @($Audit.findings)
    $top = @($findings | Where-Object { $_.status -eq 'bad' }) + @($findings | Where-Object { $_.status -eq 'warn' })
    if ($top.Count -eq 0) { [void]$L.Add('  Brak istotnych problemów.') }
    foreach ($f in @($top | Select-Object -First 5)) {
        [void]$L.Add(('  [{0}] {1}: {2}' -f (Get-StatusLabel $f.status), (Get-GroupTitle $f.group), $f.summary))
    }
    [void]$L.Add('')
    [void]$L.Add('SZCZEGÓŁY')
    foreach ($f in $findings) {
        [void]$L.Add(('- {0}: {1} - {2}' -f (Get-GroupTitle $f.group), (Get-StatusLabel $f.status), $f.summary))
        if ($f.detail) { foreach ($line in ($f.detail -split "`n")) { if ($line.Trim()) { [void]$L.Add('    ' + $line.TrimEnd()) } } }
    }
    $cand = @($Audit.candidates)
    if ($cand.Count -gt 0) {
        [void]$L.Add('')
        [void]$L.Add('DO ODZYSKANIA (kandydaci do sprzątnięcia)')
        foreach ($c in $cand) { [void]$L.Add(('  {0}: {1}' -f $c.label, (Format-Size ([long]$c.bytes)))) }
    }
    $sc = Get-AuditMetric -Audit $Audit -Name 'StartupCount'
    if ($null -ne $sc) { [void]$L.Add(''); [void]$L.Add(('Pozycji autostartu: {0}' -f $sc)) }
    $notes = @($Audit.notes)
    if ($notes.Count -gt 0) {
        [void]$L.Add('')
        [void]$L.Add('UWAGI ZBIERANIA')
        foreach ($n in $notes) { [void]$L.Add('  ' + $n) }
    }
    return ($L -join "`n")
}

function Compare-Audits {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $lines = New-Object System.Collections.ArrayList
    $b = Get-AuditMetric -Audit $Before -Name 'FreeBytes'
    $a = Get-AuditMetric -Audit $After -Name 'FreeBytes'
    if ($null -ne $b -and $null -ne $a) {
        $d = [long]$a - [long]$b
        $word = if ($d -ge 0) { 'odzyskano' } else { 'ubyło' }
        [void]$lines.Add(('Wolne miejsce: {0} -> {1} ({2} {3})' -f (Format-Size ([long]$b)), (Format-Size ([long]$a)), $word, (Format-Size ([long][math]::Abs($d)))))
    }
    $b = Get-AuditMetric -Audit $Before -Name 'BootAvgSec'
    $a = Get-AuditMetric -Audit $After -Name 'BootAvgSec'
    if ($null -ne $b -and $null -ne $a) { [void]$lines.Add(('Czas startu (średnio): {0} s -> {1} s' -f [math]::Round([double]$b), [math]::Round([double]$a))) }
    $b = Get-AuditMetric -Audit $Before -Name 'StartupCount'
    $a = Get-AuditMetric -Audit $After -Name 'StartupCount'
    if ($null -ne $b -and $null -ne $a) { [void]$lines.Add(('Pozycje autostartu: {0} -> {1}' -f $b, $a)) }
    $b = Get-AuditMetric -Audit $Before -Name 'IntegrityStatus'
    $a = Get-AuditMetric -Audit $After -Name 'IntegrityStatus'
    if ($null -ne $b -and $null -ne $a) { [void]$lines.Add(('Integralność systemu: {0} -> {1}' -f (Get-StatusLabel $b), (Get-StatusLabel $a))) }
    return @($lines)
}

function Test-IsAdmin {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { return $false }
}

function Invoke-NativeCommand {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$ArgList = @(), [int]$TimeoutSec = 0, [switch]$Quiet)
    $job = Start-Job -ScriptBlock {
        param($e, $a)
        & $e @a 2>&1 | ForEach-Object { "$_" }
        "__EXIT__:$LASTEXITCODE"
    } -ArgumentList $Exe, @($ArgList)
    $lines = New-Object System.Collections.ArrayList
    $exit = $null
    $timedOut = $false
    $start = Get-Date
    try {
        while ($true) {
            $done = Wait-Job -Job $job -Timeout 1
            foreach ($o in @(Receive-Job -Job $job -ErrorAction SilentlyContinue)) {
                $s = "$o"
                if ($s -match '^__EXIT__:(-?\d*)$') { $exit = if ($Matches[1] -ne '') { [int]$Matches[1] } else { -1 }; continue }
                [void]$lines.Add($s)
                if (-not $Quiet) { Write-Host (Hide-Secrets -Text $s) }
            }
            if ($done) { break }
            if ($TimeoutSec -gt 0 -and ((Get-Date) - $start).TotalSeconds -gt $TimeoutSec) { $timedOut = $true; break }
        }
    }
    finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    if ($timedOut) { [void]$lines.Add('Przekroczono limit czasu; polecenie mogło nadal działać w tle.'); $exit = -1 }
    if ($null -eq $exit) { $exit = -1 }
    return @{ ExitCode = $exit; Output = @($lines); TimedOut = $timedOut }
}

function New-NativeRunner {
    param([switch]$Quiet)
    $flag = if ($Quiet) { '$true' } else { '$false' }
    return [scriptblock]::Create('param($Exe, $ArgList, $TimeoutSec = 0) Invoke-NativeCommand -Exe $Exe -ArgList @($ArgList) -TimeoutSec $TimeoutSec -Quiet:' + $flag)
}

function Get-CleanupRoots {
    param([string]$SystemRoot = $env:SystemRoot, [string]$UsersDir = '')
    $sr = if ($SystemRoot -and $SystemRoot -match '^[A-Za-z]:\\') { $SystemRoot.TrimEnd('\') } else { 'C:\Windows' }
    if (-not $UsersDir) { $UsersDir = '{0}\Users' -f $(if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }) }
    $userTemps = @()
    if (Test-Path -LiteralPath $UsersDir) {
        $userTemps = @(Get-ChildItem -LiteralPath $UsersDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { '{0}\AppData\Local\Temp' -f $_.FullName })
    }
    return [ordered]@{
        'temp-user'   = $userTemps
        'temp-win'    = @('{0}\Temp' -f $sr)
        'wu-download' = @('{0}\SoftwareDistribution\Download' -f $sr)
        'dumps'       = @(('{0}\Minidump' -f $sr), ('{0}\LiveKernelReports' -f $sr))
    }
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0L
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) { $sum += [long]$f.Length }
    return $sum
}

function Test-ProtectedStartupItem {
    param([Parameter(Mandatory)]$Item)
    if ($Item.Kind -eq 'folder') { return $true }
    $pub = "$($Item.Publisher)"
    if ($pub -match '(?i)microsoft') { return $true }
    $sec = '(?i)antivir|defender|security|kaspersky|eset|bitdefender|norton|mcafee|sophos|avast|\bavg\b|malwarebytes|trend micro|f-secure|crowdstrike|sentinel'
    if ("$($Item.Name)" -match $sec -or $pub -match $sec) { return $true }
    return $false
}

function Get-FilePublisher {
    param([string]$Command)
    if (-not $Command) { return '' }
    if ($Command -notmatch '^\s*"?([^"]+?\.(exe|dll|sys))') { return '' }
    try { return "$((Get-Item -LiteralPath $Matches[1] -ErrorAction Stop).VersionInfo.CompanyName)" } catch { return '' }
}

function Get-StartupItems {
    # Tylko Windows. Zwraca wpisy Run, zadania z wyzwalaczem logowania/startu, usługi automatyczne i skróty z Autostartu.
    $items = New-Object System.Collections.ArrayList
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
        $p = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $it = @{ Name = $prop.Name; Kind = 'run'; Command = "$($prop.Value)"; Publisher = (Get-FilePublisher "$($prop.Value)"); Location = $key; Disableable = $true; Reason = '' }
            $prot = Test-ProtectedStartupItem -Item $it
            $it.Disableable = -not $prot; if ($prot) { $it.Reason = 'chronione' }
            [void]$items.Add($it)
        }
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' })) {
        $trig = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' })
        if ($trig.Count -eq 0) { continue }
        $cmd = if (@($t.Actions).Count -gt 0) { "$($t.Actions[0].Execute)" } else { '' }
        $it = @{ Name = $t.TaskName; Kind = 'task'; Command = $cmd; Publisher = (Get-FilePublisher $cmd); Location = $t.TaskPath; Disableable = $true; Reason = '' }
        $prot = Test-ProtectedStartupItem -Item $it
        $it.Disableable = -not $prot; if ($prot) { $it.Reason = 'chronione' }
        [void]$items.Add($it)
    }
    foreach ($s in @(Get-CimInstance Win32_Service -Filter "StartMode='Auto'" -ErrorAction SilentlyContinue)) {
        if ("$($s.PathName)" -match '(?i)\\windows\\system32\\') { continue }
        $it = @{ Name = $s.Name; Kind = 'service'; Command = "$($s.PathName)"; Publisher = (Get-FilePublisher "$($s.PathName)"); Location = 'service'; Disableable = $true; Reason = '' }
        $prot = Test-ProtectedStartupItem -Item $it
        $it.Disableable = -not $prot; if ($prot) { $it.Reason = 'chronione' }
        [void]$items.Add($it)
    }
    foreach ($dir in ('{0}\Microsoft\Windows\Start Menu\Programs\StartUp' -f $env:ProgramData), ('{0}\Microsoft\Windows\Start Menu\Programs\Startup' -f $env:APPDATA)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            [void]$items.Add(@{ Name = $f.Name; Kind = 'folder'; Command = $f.FullName; Publisher = ''; Location = $dir; Disableable = $false; Reason = 'wyłącz ręcznie (folder Autostart)' })
        }
    }
    return @($items)
}

function Get-DiskFacts {
    param($Runner)
    $out = @()
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
        $rc = $null
        try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $out += @{
            Name       = "$($d.FriendlyName)"
            Health     = "$($d.HealthStatus)"
            Wear       = $(if ($rc -and $null -ne $rc.Wear) { [int]$rc.Wear } else { $null })
            Unreadable = $(if ($rc -and $null -ne $rc.ReadErrorsUncorrected) { [long]$rc.ReadErrorsUncorrected } else { $null })
        }
    }
    return @{ Disks = @($out) }
}

function Get-SpaceFacts {
    param($Runner)
    $sys = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object { @{ Drive = "$($_.DeviceID)"; Free = [long]$_.FreeSpace; Total = [long]$_.Size } })
    return @{ SystemDrive = $sys; Drives = $drives }
}

function Get-CandidateSizes {
    param($Runner)
    $sizes = [ordered]@{}
    $roots = Get-CleanupRoots
    foreach ($id in $roots.Keys) {
        $sum = 0L
        foreach ($p in $roots[$id]) { $sum += Get-DirectorySize -Path $p }
        $sizes[$id] = $sum
    }
    $sd = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $sizes['recycle'] = Get-DirectorySize -Path ('{0}\$Recycle.Bin' -f $sd)
    $hib = Get-Item -LiteralPath ('{0}\hiberfil.sys' -f $sd) -Force -ErrorAction SilentlyContinue
    $sizes['hibernate'] = $(if ($hib) { [long]$hib.Length } else { 0L })
    $cs = & $Runner 'dism.exe' @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') 600
    return @{ Sizes = $sizes; ComponentStoreCleanupRecommended = (ConvertFrom-AnalyzeComponentStore -Text ($cs.Output -join "`n")) }
}

function Get-BootFacts {
    param($Runner)
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 10 -ErrorAction Stop)
    $secs = @()
    foreach ($e in $events) {
        $x = [xml]$e.ToXml()
        $d = $x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' } | Select-Object -First 1
        if ($d) { $secs += ([double]$d.'#text') / 1000.0 }
    }
    return @{ Seconds = @($secs) }
}

function Get-IntegrityFacts {
    param($Runner)
    $r = & $Runner 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth') 300
    $log = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    $lines = @()
    if (Test-Path -LiteralPath $log) { $lines = @(Get-Content -LiteralPath $log -Tail 20000 -ErrorAction SilentlyContinue) }
    return @{ Dism = (ConvertFrom-DismCheckHealth -Text ($r.Output -join "`n")); SfcUnrepaired = (Get-SfcLogSummary -Lines $lines).Unrepaired }
}

function Test-PendingReboot {
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        try { if (Test-Path -LiteralPath $k) { return $true } } catch { }
    }
    return $false
}

function Get-UpdateFacts {
    param($Runner)
    $types = @{}
    foreach ($n in 'wuauserv', 'BITS', 'cryptsvc') {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { $types[$n] = "$($s.StartType)" }
    }
    $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $days = $null
    if ($hf) { $days = [int]((Get-Date) - [datetime]$hf.InstalledOn).TotalDays }
    $codes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = 20; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Message -match '0x[0-9A-Fa-f]{8}') { $Matches[0] } })
    $rep = $codes | Group-Object | Where-Object { $_.Count -ge 3 } | Sort-Object Count -Descending | Select-Object -First 1
    return @{ StartTypes = $types; DaysSinceInstall = $days; PendingReboot = (Test-PendingReboot); RepeatedErrorCode = $(if ($rep) { $rep.Name } else { $null }) }
}

function Get-MemoryFacts {
    param($Runner)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $total = [double]$os.TotalVisibleMemorySize
    $top = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object { '{0} ({1})' -f $_.ProcessName, (Format-Size ([long]$_.WorkingSet64)) })
    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue).Count
    return @{ TotalGB = [math]::Round($total / 1MB, 1); UsedPct = [math]::Round(100.0 * ($total - [double]$os.FreePhysicalMemory) / $total, 0); CrashCount = $crashes; TopProcesses = $top }
}

function Get-DefaultCollectors {
    return @{
        disk       = { param($r) Get-DiskFacts -Runner $r }
        space      = { param($r) Get-SpaceFacts -Runner $r }
        candidates = { param($r) Get-CandidateSizes -Runner $r }
        boot       = { param($r) Get-BootFacts -Runner $r }
        startup    = { param($r) @{ Items = @(Get-StartupItems) } }
        integrity  = { param($r) Get-IntegrityFacts -Runner $r }
        updates    = { param($r) Get-UpdateFacts -Runner $r }
        memory     = { param($r) Get-MemoryFacts -Runner $r }
    }
}

function Invoke-RepairAudit {
    param(
        [hashtable]$Collectors = (Get-DefaultCollectors),
        [scriptblock]$Runner = (New-NativeRunner -Quiet),
        [datetime]$Now = (Get-Date),
        [string]$ComputerName = $env:COMPUTERNAME
    )
    $findings = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $metrics = [ordered]@{ FreeBytes = $null; BootAvgSec = $null; StartupCount = $null; IntegrityStatus = $null }
    $candidates = @()
    $startup = @()
    $componentStore = $null

    $collect = {
        param($name)
        try { return @{ Ok = $true; Data = (& $Collectors[$name] $Runner) } }
        catch { return @{ Ok = $false; Reason = $_.Exception.Message } }
    }
    $noData = {
        param($group, $reason)
        [void]$findings.Add((New-Finding -Group $group -Status 'nodata' -Summary ('Brak danych: {0}' -f $reason)))
    }

    # dysk fizyczny
    $r = & $collect 'disk'
    if ($r.Ok) {
        $st = Get-DiskHealthStatus -Disks @($r.Data.Disks)
        $detail = (@($r.Data.Disks) | ForEach-Object { '{0}: {1}{2}' -f $_.Name, $_.Health, $(if ($null -ne $_.Wear) { ", zużycie $($_.Wear)%" } else { '' }) }) -join "`n"
        if ($st -eq 'nodata') { & $noData 'disk' 'brak odczytu dysków fizycznych' }
        else { [void]$findings.Add((New-Finding -Group 'disk' -Status $st -Summary (Get-FindingSummary -Group 'disk' -Status $st) -Detail $detail)) }
    }
    else { & $noData 'disk' $r.Reason }

    # miejsce
    $r = & $collect 'space'
    if ($r.Ok) {
        $stList = @(); $detail = @(); $sysFree = $null
        foreach ($d in @($r.Data.Drives)) {
            $stList += (Get-SpaceStatus -FreeBytes ([long]$d.Free) -TotalBytes ([long]$d.Total))
            $detail += ('{0}: wolne {1} z {2}' -f $d.Drive, (Format-Size ([long]$d.Free)), (Format-Size ([long]$d.Total)))
            if ($d.Drive -eq $r.Data.SystemDrive) { $sysFree = [long]$d.Free }
        }
        $st = Get-WorstAuditStatus -Statuses $stList
        if ($st -eq 'nodata') { & $noData 'space' 'brak odczytu woluminów' }
        else { [void]$findings.Add((New-Finding -Group 'space' -Status $st -Summary (Get-FindingSummary -Group 'space' -Status $st) -Detail ($detail -join "`n"))) }
        $metrics['FreeBytes'] = $sysFree
    }
    else { & $noData 'space' $r.Reason }

    # kandydaci (bez oceny)
    $r = & $collect 'candidates'
    if ($r.Ok) { $candidates = @(Get-CleanupCandidates -Sizes $r.Data.Sizes); $componentStore = $r.Data.ComponentStoreCleanupRecommended }
    else { [void]$notes.Add(('Brak danych: kandydaci do sprzątnięcia ({0})' -f $r.Reason)) }

    # start
    $r = & $collect 'boot'
    if ($r.Ok) {
        $secs = @($r.Data.Seconds | ForEach-Object { [double]$_ })
        $st = Get-BootStatus -Seconds $secs
        if ($st -eq 'nodata') { & $noData 'boot' 'brak zdarzeń czasu startu' }
        else {
            $avg = [math]::Round(($secs | Measure-Object -Average).Average)
            [void]$findings.Add((New-Finding -Group 'boot' -Status $st -Summary (Get-FindingSummary -Group 'boot' -Status $st) -Detail ('Średnio {0} s z {1} ostatnich startów' -f $avg, $secs.Count)))
            $metrics['BootAvgSec'] = ($secs | Measure-Object -Average).Average
        }
    }
    else { & $noData 'boot' $r.Reason }

    # autostart (bez oceny)
    $r = & $collect 'startup'
    if ($r.Ok) { $startup = @($r.Data.Items); $metrics['StartupCount'] = $startup.Count }
    else { [void]$notes.Add(('Brak danych: autostart ({0})' -f $r.Reason)) }

    # integralność
    $r = & $collect 'integrity'
    if ($r.Ok) {
        $st = Get-IntegrityStatus -Dism $r.Data.Dism -SfcUnrepaired ([int]$r.Data.SfcUnrepaired)
        if ($st -eq 'nodata') { & $noData 'integrity' 'nie rozpoznano wyniku DISM (inny język systemu?)' }
        else { [void]$findings.Add((New-Finding -Group 'integrity' -Status $st -Summary (Get-FindingSummary -Group 'integrity' -Status $st) -Detail ('DISM: {0}; niezałatane pliki w ostatnim sfc: {1}' -f $r.Data.Dism, $r.Data.SfcUnrepaired))) }
        $metrics['IntegrityStatus'] = $st
    }
    else { & $noData 'integrity' $r.Reason }

    # aktualizacje
    $r = & $collect 'updates'
    if ($r.Ok) {
        $st = Get-UpdateStatus -StartTypes $r.Data.StartTypes -DaysSinceInstall $r.Data.DaysSinceInstall -PendingReboot ([bool]$r.Data.PendingReboot) -RepeatedErrorCode $r.Data.RepeatedErrorCode
        if ($st -eq 'nodata') { & $noData 'updates' 'brak informacji o ostatniej aktualizacji' }
        else { [void]$findings.Add((New-Finding -Group 'updates' -Status $st -Summary (Get-FindingSummary -Group 'updates' -Status $st) -Detail ('Ostatnia instalacja: {0} dni temu; oczekuje restart: {1}; powtarzający się błąd: {2}' -f $r.Data.DaysSinceInstall, $r.Data.PendingReboot, $(if ($r.Data.RepeatedErrorCode) { $r.Data.RepeatedErrorCode } else { 'brak' })))) }
    }
    else { & $noData 'updates' $r.Reason }

    # pamięć
    $r = & $collect 'memory'
    if ($r.Ok) {
        $st = Get-MemoryStatus -TotalGB ([double]$r.Data.TotalGB) -UsedPct ([double]$r.Data.UsedPct) -CrashCount ([int]$r.Data.CrashCount)
        [void]$findings.Add((New-Finding -Group 'memory' -Status $st -Summary (Get-FindingSummary -Group 'memory' -Status $st) -Detail ("RAM {0} GB, zajęte {1}%; restarty awaryjne (30 dni): {2}`nNajwięksi: {3}" -f $r.Data.TotalGB, $r.Data.UsedPct, $r.Data.CrashCount, (@($r.Data.TopProcesses) -join ', '))))
    }
    else { & $noData 'memory' $r.Reason }

    return [pscustomobject]@{
        version        = 1
        computer       = $ComputerName
        generated      = $Now.ToString('s')
        findings       = @($findings)
        candidates     = @($candidates)
        startup        = @($startup)
        componentStore = $componentStore
        notes          = @($notes)
        metrics        = $metrics
    }
}

function New-RepairRunDir {
    param([Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][datetime]$Now)
    $parent = Join-Path $WorkDir 'repair'
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') { Set-RestrictedAcl -Path $parent }
    $dir = Join-Path $parent $Now.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Save-AuditFile {
    param([Parameter(Mandatory)]$Audit, [Parameter(Mandatory)][string]$Dir, [string]$Name = 'audit')
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
    $p = Join-Path $Dir ($Name + '.json')
    $Audit | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p -Encoding UTF8
    return $p
}

function Get-RepairFacts {
    $free = $null
    try {
        $sd = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        $free = [long](Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $sd) -ErrorAction Stop).FreeSpace
    }
    catch { }
    $battery = $false
    try { $battery = [bool](Test-OnBattery) } catch { }
    return @{ IsAdmin = (Test-IsAdmin); OnBattery = $battery; SystemFreeBytes = $free; PendingReboot = (Test-PendingReboot) }
}

function Get-RepairPreflightErrors {
    param([Parameter(Mandatory)]$Facts)
    $errors = @(); $warnings = @()
    if (-not $Facts.IsAdmin) { $errors += 'Uruchom jako administrator (Start.cmd robi to automatycznie).' }
    if ($Facts.OnBattery) { $errors += 'Komputer pracuje na baterii: podłącz zasilanie, naprawa trwa długo.' }
    if ($Facts.PendingReboot) { $errors += 'Czeka restart systemu: uruchom komputer ponownie i spróbuj jeszcze raz.' }
    if ($null -eq $Facts.SystemFreeBytes) { $warnings += 'Nie można sprawdzić wolnego miejsca na dysku systemowym.' }
    elseif ([long]$Facts.SystemFreeBytes -lt 2GB) { $errors += 'Za mało wolnego miejsca na dysku systemowym (potrzeba co najmniej 2 GB na narzędzia naprawcze).' }
    return @{ Errors = @($errors); Warnings = @($warnings) }
}

function Get-BackupGate {
    param($LastRun, [Parameter(Mandatory)][datetime]$Now, [Nullable[datetime]]$ImageDate = $null, [string]$SkipReason = '')
    if ($SkipReason -and $SkipReason.Trim()) {
        return @{ Allowed = $true; Basis = 'skip'; Message = ('Kontrola kopii pominięta, powód: {0}' -f $SkipReason.Trim()) }
    }
    if ($LastRun -and (Get-ConfigValue $LastRun 'status' '') -ne 'fail' -and (Get-DailyStaleness -LastRun $LastRun -Now $Now) -eq 'fresh') {
        return @{ Allowed = $true; Basis = 'daily'; Message = 'Świeża kopia codzienna (ostatni sukces w ciągu 48 h).' }
    }
    if ($null -ne $ImageDate) {
        $age = ($Now - ([datetime]$ImageDate)).TotalDays
        if ($age -le 30 -and $age -ge -1) {
            return @{ Allowed = $true; Basis = 'image'; Message = ('Obraz systemu z {0} (zadeklarowany przez technika).' -f ([datetime]$ImageDate).ToString('yyyy-MM-dd')) }
        }
    }
    return @{ Allowed = $false; Basis = 'none'; Message = 'Brak świeżej kopii: wykonaj kopię codzienną albo obraz systemu (faza 0) i podaj -ImageDate RRRR-MM-DD, albo użyj -SkipBackupCheck "powód".' }
}

function ConvertTo-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    if ($p -match '^[A-Za-z]:') { return $p.Replace('/', '\').TrimEnd('\') }
    return $p.TrimEnd('/')
}

function Test-SafeDeleteTarget {
    param([string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$AllowedRoots)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    $p = ConvertTo-NormalizedPath -Path $Path
    if ($p -notmatch '^([A-Za-z]:\\|/)[^\\/]') { return $false }
    $sep = if ($p -match '^[A-Za-z]:') { '\' } else { '/' }
    $pl = $p.ToLowerInvariant()
    foreach ($r in $AllowedRoots) {
        $rn = ConvertTo-NormalizedPath -Path $r
        if ($rn -notmatch '^([A-Za-z]:\\|/)[^\\/]') { continue }
        $rl = $rn.ToLowerInvariant()
        if ($pl -eq $rl -or $pl.StartsWith($rl + $sep)) { return $true }
    }
    return $false
}

function Remove-FolderContents {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$AllowedRoots, [int]$OlderThanDays = 0, [datetime]$Now = (Get-Date))
    $res = @{ FreedBytes = 0L; Failed = 0; Skipped = 0 }
    if (-not (Test-SafeDeleteTarget -Path $Path -AllowedRoots $AllowedRoots)) { throw ('Odmowa: ścieżka poza dozwolonymi katalogami: {0}' -f $Path) }
    if (-not (Test-Path -LiteralPath $Path)) { return $res }
    $cut = $Now.AddDays(-$OlderThanDays)
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if ($item.LinkType) { $res.Skipped++; continue }
        if ($OlderThanDays -gt 0 -and $item.LastWriteTime -gt $cut) { $res.Skipped++; continue }
        if ($item.PSIsContainer) {
            $links = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
            if ($links.Count -gt 0) { $res.Skipped++; continue }
            $size = Get-DirectorySize -Path $item.FullName
        }
        else { $size = [long]$item.Length }
        try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop; $res.FreedBytes += $size }
        catch { $res.Failed++ }
    }
    return $res
}

function New-SafetyRestorePoint {
    param([Parameter(Mandatory)][scriptblock]$Creator)
    try {
        $w = @(& $Creator | Where-Object { $_ })
        if ($w.Count -gt 0) { return @{ Created = $false; Message = ($w -join '; ') } }
        return @{ Created = $true; Message = 'Utworzono punkt przywracania.' }
    }
    catch { return @{ Created = $false; Message = $_.Exception.Message } }
}

function Invoke-RepairGate {
    param(
        [Parameter(Mandatory)]$Facts, $LastRun, [Parameter(Mandatory)][datetime]$Now,
        [Nullable[datetime]]$ImageDate = $null, [string]$SkipReason = '',
        [Parameter(Mandatory)][scriptblock]$Creator, [Parameter(Mandatory)][scriptblock]$Ask
    )
    $msgs = @()
    $pre = Get-RepairPreflightErrors -Facts $Facts
    foreach ($w in $pre.Warnings) { $msgs += "Uwaga: $w" }
    if ($pre.Errors.Count -gt 0) {
        return @{ Allowed = $false; Messages = @($msgs + $pre.Errors); RestorePoint = $false; Basis = 'none' }
    }
    $bk = Get-BackupGate -LastRun $LastRun -Now $Now -ImageDate $ImageDate -SkipReason $SkipReason
    $msgs += $bk.Message
    if (-not $bk.Allowed) { return @{ Allowed = $false; Messages = @($msgs); RestorePoint = $false; Basis = $bk.Basis } }
    $rp = New-SafetyRestorePoint -Creator $Creator
    if ($rp.Created) { $msgs += $rp.Message; return @{ Allowed = $true; Messages = @($msgs); RestorePoint = $true; Basis = $bk.Basis } }
    $q = "Nie utworzono punktu przywracania ($($rp.Message)). Podstawa bezpieczeństwa: $($bk.Message) Kontynuować bez punktu? (t/n)"
    if (& $Ask $q) { $msgs += 'Kontynuacja bez punktu przywracania (decyzja technika).'; return @{ Allowed = $true; Messages = @($msgs); RestorePoint = $false; Basis = $bk.Basis } }
    return @{ Allowed = $false; Messages = @($msgs + 'Przerwano: brak punktu przywracania.'); RestorePoint = $false; Basis = $bk.Basis }
}

function Get-DefaultOps {
    return @{
        Service         = {
            param($Name, $Action)
            $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
            switch ($Action) {
                'state' { if ($s) { return "$($s.Status)" } return $null }
                'stop' { if ($s) { Stop-Service -Name $Name -Force -ErrorAction Stop; $s.WaitForStatus('Stopped', [timespan]::FromSeconds(30)) } }
                'start' { if ($s) { Start-Service -Name $Name -ErrorAction Stop } }
            }
        }
        ClearRecycleBin = { Clear-RecycleBin -Force -ErrorAction Stop }
        RenameItem      = { param($From, $To) Rename-Item -LiteralPath $From -NewName (Split-Path -Leaf $To) -ErrorAction Stop }
        DisableStartup  = {
            param($Item)
            switch ($Item.Kind) {
                'run' {
                    $val = [string](Get-ItemProperty -LiteralPath $Item.Location -Name $Item.Name -ErrorAction Stop).($Item.Name)
                    $bak = 'HKLM:\SOFTWARE\WinResurect\DisabledStartup'
                    if (-not (Test-Path -LiteralPath $bak)) { New-Item -Path $bak -Force | Out-Null }
                    $hive = if ($Item.Location -like 'HKCU*') { 'HKCU' } else { 'HKLM' }
                    New-ItemProperty -LiteralPath $bak -Name ('{0}|{1}' -f $hive, $Item.Name) -Value $val -PropertyType String -Force | Out-Null
                    Remove-ItemProperty -LiteralPath $Item.Location -Name $Item.Name -ErrorAction Stop
                    return @{ kind = 'run'; name = $Item.Name; location = $Item.Location; value = $val }
                }
                'task' {
                    Disable-ScheduledTask -TaskName $Item.Name -TaskPath $Item.Location -ErrorAction Stop | Out-Null
                    return @{ kind = 'task'; name = $Item.Name; location = $Item.Location }
                }
                'service' {
                    $prev = "$((Get-Service -Name $Item.Name -ErrorAction Stop).StartType)"
                    Set-Service -Name $Item.Name -StartupType Manual -ErrorAction Stop
                    return @{ kind = 'service'; name = $Item.Name; location = 'service'; previous = $prev }
                }
                default { throw ('Nieobsługiwany rodzaj wpisu: {0}' -f $Item.Kind) }
            }
        }
        EnableStartup   = {
            param($Rec)
            switch ($Rec.kind) {
                'run' {
                    Set-ItemProperty -LiteralPath $Rec.location -Name $Rec.name -Value $Rec.value -ErrorAction Stop
                    $hive = if ($Rec.location -like 'HKCU*') { 'HKCU' } else { 'HKLM' }
                    Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WinResurect\DisabledStartup' -Name ('{0}|{1}' -f $hive, $Rec.name) -ErrorAction SilentlyContinue
                }
                'task' { Enable-ScheduledTask -TaskName $Rec.name -TaskPath $Rec.location -ErrorAction Stop | Out-Null }
                'service' {
                    $t = if ($Rec.previous -in 'Automatic', 'Manual', 'Disabled') { $Rec.previous } else { 'Automatic' }
                    Set-Service -Name $Rec.name -StartupType $t -ErrorAction Stop
                }
            }
        }
    }
}

function New-RepairContext {
    param(
        $Audit, [string]$RunDir = '', [hashtable]$Ops = (Get-DefaultOps), [scriptblock]$Runner = (New-NativeRunner),
        [scriptblock]$Ask = { param($q) (Read-Host $q) -match '^[TtYy]' }, [scriptblock]$Prompt = { param($q) Read-Host $q },
        [datetime]$Now = (Get-Date), [string]$SystemRoot = '', [hashtable]$Roots = $null
    )
    $sr = 'C:\Windows'
    if ($SystemRoot -and $SystemRoot -match '^([A-Za-z]:\\|/)') { $sr = $SystemRoot.TrimEnd('\', '/') }
    elseif (-not $SystemRoot -and $env:SystemRoot -and $env:SystemRoot -match '^[A-Za-z]:\\') { $sr = $env:SystemRoot.TrimEnd('\') }
    if (-not $Roots -or $Roots.Count -eq 0) { $Roots = Get-CleanupRoots -SystemRoot $sr }
    return @{ Audit = $Audit; RunDir = $RunDir; Ops = $Ops; Runner = $Runner; Ask = $Ask; Prompt = $Prompt; Now = $Now; SystemRoot = $sr; Roots = $Roots }
}

function Invoke-RepairModule {
    param([Parameter(Mandatory)][hashtable]$Module, [Parameter(Mandatory)][hashtable]$Context)
    $name = $Module.Name
    try {
        if (-not (& $Module.Test $Context)) { return @{ Name = $name; Status = 'skipped'; Messages = @('Nic do zrobienia.') } }
        $plan = @(& $Module.Plan $Context)
        $text = ('Moduł: {0}' -f $Module.Title) + "`n  - " + ($plan -join "`n  - ") + "`nWykonać? (t/n)"
        if (-not (& $Context.Ask $text)) { return @{ Name = $name; Status = 'declined'; Messages = @('Pominięte na życzenie technika.') } }
        $r = & $Module.Apply $Context
        return @{ Name = $name; Status = $r.Status; Messages = @($r.Messages) }
    }
    catch { return @{ Name = $name; Status = 'fail'; Messages = @(('Błąd: {0}' -f $_.Exception.Message)) } }
}

function Get-CleanupModule {
    return @{
        Name  = 'cleanup'
        Title = 'Czyszczenie dysku'
        Test  = {
            param($c)
            (@($c.Audit.candidates | Where-Object { $_.bytes -gt 0 }).Count -gt 0) -or ($c.Audit.componentStore -eq $true)
        }
        Plan  = {
            param($c)
            $lines = @()
            foreach ($x in @($c.Audit.candidates)) { $lines += ('{0}: {1}' -f $x.label, (Format-Size ([long]$x.bytes))) }
            if ($c.Audit.componentStore -eq $true) { $lines += 'Magazyn składników WinSxS: StartComponentCleanup (bez ResetBase)' }
            $lines += 'Pliki tymczasowe: tylko starsze niż 7 dni, zablokowane zostaną pominięte. Kosz i hibernacja: osobne pytanie.'
            return $lines
        }
        Apply = {
            param($c)
            $ids = @($c.Audit.candidates | ForEach-Object { $_.id })
            $msgs = @(); $freed = 0L; $failed = 0; $skipped = 0
            $wuWasRunning = $false
            try {
                if ($ids -contains 'wu-download') {
                    $wuWasRunning = ((& $c.Ops.Service 'wuauserv' 'state') -eq 'Running')
                    if ($wuWasRunning) { & $c.Ops.Service 'wuauserv' 'stop' | Out-Null }
                }
                foreach ($id in 'temp-user', 'temp-win', 'wu-download', 'dumps') {
                    if ($ids -notcontains $id) { continue }
                    $age = if ($id -in 'temp-user', 'temp-win') { 7 } else { 0 }
                    $paths = @($c.Roots[$id] | Where-Object { $_ })
                    foreach ($p in $paths) {
                        $r = Remove-FolderContents -Path $p -AllowedRoots $paths -OlderThanDays $age -Now $c.Now
                        $freed += $r.FreedBytes; $failed += $r.Failed; $skipped += $r.Skipped
                    }
                }
            }
            finally {
                if ($wuWasRunning) { & $c.Ops.Service 'wuauserv' 'start' | Out-Null }
            }
            if ($ids -contains 'recycle' -and (& $c.Ask 'Opróżnić kosz? Tego nie da się cofnąć. (t/n)')) {
                & $c.Ops.ClearRecycleBin
                $msgs += 'Kosz opróżniony.'
            }
            if ($ids -contains 'hibernate' -and (& $c.Ask 'Wyłączyć hibernację (usuwa hiberfil.sys i wyłącza szybki start)? (t/n)')) {
                $r = & $c.Runner 'powercfg.exe' @('-h', 'off') 60
                $msgs += $(if ($r.ExitCode -eq 0) { 'Hibernacja wyłączona.' } else { ('powercfg -h off zakończyło się kodem {0}.' -f $r.ExitCode) })
            }
            if ($c.Audit.componentStore -eq $true) {
                $r = & $c.Runner 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup') 3600
                $msgs += $(if ($r.ExitCode -eq 0) { 'Magazyn składników wyczyszczony.' } else { ('DISM StartComponentCleanup: kod {0}.' -f $r.ExitCode) })
            }
            $msgs = @(('Zwolniono ok. {0} (pominięto: {1}, nieudane: {2}).' -f (Format-Size $freed), $skipped, $failed)) + $msgs
            return @{ Status = 'done'; Messages = $msgs }
        }
    }
}

function ConvertFrom-SfcOutput {
    param([AllowEmptyString()][string]$Text = '')
    $t = $Text -replace "`0", ''
    if ($t -match '(?i)unable to fix|nie mo[żz]e naprawi|nie uda[łl]o si[ęe] naprawi') { return 'unrepairable' }
    if ($t -match '(?i)successfully repaired|pomy[śs]lnie (je )?napraw') { return 'repaired' }
    if ($t -match '(?i)did not find any integrity violations|nie wykry[łl]a [żz]adnych naruszeń|nie wykry[łl]a naruszeń') { return 'clean' }
    return 'unknown'
}

function Get-SystemRepairVerdict {
    param([Parameter(Mandatory)]$Restore, [Parameter(Mandatory)]$Sfc, [Parameter(Mandatory)]$Check)
    $msgs = @(); $status = 'done'
    $steps = @(@{ T = 'DISM /RestoreHealth'; R = $Restore }, @{ T = 'sfc /scannow'; R = $Sfc }, @{ T = 'DISM /CheckHealth'; R = $Check })
    foreach ($s in $steps) { if ($s.R.TimedOut) { $status = 'fail'; $msgs += ('{0}: przekroczono limit czasu.' -f $s.T) } }
    if ($status -eq 'fail') { return @{ Status = $status; Messages = $msgs } }
    if ($Restore.ExitCode -ne 0) {
        $status = 'fail'
        $msgs += ('DISM /RestoreHealth nie powiódł się (kod {0}). Spróbuj z nośnika: DISM /Online /Cleanup-Image /RestoreHealth /Source:<ISO>\sources\install.wim /LimitAccess (parametr Source).' -f $Restore.ExitCode)
    }
    else { $msgs += 'DISM /RestoreHealth: zakończony.' }
    switch (ConvertFrom-SfcOutput -Text ($Sfc.Output -join "`n")) {
        'clean' { $msgs += 'sfc: nie wykryto naruszeń integralności.' }
        'repaired' { $msgs += 'sfc: uszkodzone pliki zostały naprawione.' }
        'unrepairable' { $status = 'fail'; $msgs += 'sfc: nie wszystkie pliki udało się naprawić; użyj DISM z nośnika (Source) i powtórz.' }
        default { $msgs += 'sfc: nie rozpoznano wyniku (inny język systemu?); sprawdź C:\Windows\Logs\CBS\CBS.log.' }
    }
    switch (ConvertFrom-DismCheckHealth -Text ($Check.Output -join "`n")) {
        'healthy' { $msgs += 'DISM /CheckHealth: magazyn składników bez uszkodzeń.' }
        'unknown' { $msgs += 'DISM /CheckHealth: nie rozpoznano wyniku (inny język systemu?).' }
        default { $status = 'fail'; $msgs += 'DISM /CheckHealth: magazyn składników nadal uszkodzony.' }
    }
    return @{ Status = $status; Messages = $msgs }
}

function Get-SystemRepairModule {
    return @{
        Name  = 'system-repair'
        Title = 'Naprawa plików systemowych'
        Test  = { param($c) $true }
        Plan  = { param($c) @('DISM /RestoreHealth (10-40 min)', 'sfc /scannow (10-30 min)', 'DISM /CheckHealth', 'Limit 60 min na krok; postęp widać na ekranie, wynik trafi do raportu.') }
        Apply = {
            param($c)
            $restore = & $c.Runner 'dism.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth') 3600
            $sfc = & $c.Runner 'sfc.exe' @('/scannow') 3600
            $check = & $c.Runner 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth') 600
            return (Get-SystemRepairVerdict -Restore $restore -Sfc $sfc -Check $check)
        }
    }
}

function Get-UndoPath { param([Parameter(Mandatory)][string]$Dir) return (Join-Path $Dir 'undo.json') }

function Read-UndoRecords {
    param([Parameter(Mandatory)][string]$Dir)
    $p = Get-UndoPath -Dir $Dir
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    try { $o = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { return @() }
    return @(Expand-JsonItems $o)
}

function Save-UndoRecords {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
    ConvertTo-Json -InputObject @($Records) -Depth 6 | Set-Content -LiteralPath (Get-UndoPath -Dir $Dir) -Encoding UTF8
}

function Add-UndoRecord {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][hashtable]$Record)
    $all = @(Read-UndoRecords -Dir $Dir) + @([pscustomobject]$Record)
    Save-UndoRecords -Dir $Dir -Records $all
}

function Test-UndoDone {
    param($Record)
    $p = $Record.PSObject.Properties['undone']
    return [bool]($p -and $p.Value)
}

function Set-UndoDone {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Module)
    $all = @(Read-UndoRecords -Dir $Dir)
    foreach ($r in $all) { if ($r.module -eq $Module) { $r | Add-Member -NotePropertyName undone -NotePropertyValue $true -Force } }
    Save-UndoRecords -Dir $Dir -Records $all
}

function Get-LatestUndoDir {
    param([Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string]$Module)
    $base = Join-Path $WorkDir 'repair'
    if (-not (Test-Path -LiteralPath $base)) { return $null }
    foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name -Descending)) {
        $recs = @(Read-UndoRecords -Dir $d.FullName | Where-Object { $_.module -eq $Module -and -not (Test-UndoDone $_) })
        if ($recs.Count -gt 0) { return $d.FullName }
    }
    return $null
}

function ConvertFrom-NumberSelection {
    param([AllowEmptyString()][string]$Text = '', [Parameter(Mandatory)][int]$Max)
    $invalid = @{ Valid = $false; Numbers = @() }
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Valid = $true; Numbers = @() } }
    $set = New-Object System.Collections.Generic.SortedSet[int]
    try {
        foreach ($part in $Text.Split(',')) {
            $p = $part.Trim()
            if ($p -match '^(\d+)$') { $a = [int]$Matches[1]; $b = $a }
            elseif ($p -match '^(\d+)\s*-\s*(\d+)$') { $a = [int]$Matches[1]; $b = [int]$Matches[2] }
            else { return $invalid }
            if ($a -lt 1 -or $b -gt $Max -or $a -gt $b) { return $invalid }
            for ($i = $a; $i -le $b; $i++) { [void]$set.Add($i) }
        }
    }
    catch { return $invalid }
    return @{ Valid = $true; Numbers = @($set) }
}

function Get-StartupList {
    param([Parameter(Mandatory)]$Audit)
    return @(@($Audit.startup) | Sort-Object { $_.Name })
}

function Get-ExpiredBackups {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names, [Parameter(Mandatory)][datetime]$Now, [int]$Days = 14)
    $out = @()
    foreach ($n in $Names) {
        if ($n -notmatch '^(SoftwareDistribution|catroot2)\.bak-(\d{8})(-\d{6})?$') { continue }
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($Matches[2], 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
            if (($Now - $d).TotalDays -gt $Days) { $out += $n }
        }
    }
    return @($out)
}

function Get-WindowsUpdateModule {
    return @{
        Name  = 'windows-update'
        Title = 'Reset komponentów Windows Update'
        Test  = { param($c) $true }
        Plan  = {
            param($c)
            @('Zatrzymanie usług: BITS, wuauserv, appidsvc, cryptsvc',
                'Zmiana nazwy (nie usunięcie): SoftwareDistribution i catroot2 na *.bak-<data>',
                'netsh winsock reset (działa po restarcie)',
                'Uruchomienie usług, które działały. Aktualizacje nie są instalowane, restart nie jest wymuszany.')
        }
        Apply = {
            param($c)
            $svc = 'BITS', 'wuauserv', 'appidsvc', 'cryptsvc'
            $was = @{}
            $msgs = @()
            $sr = $c.SystemRoot
            $stamp = $c.Now.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
            $dirs = @((Join-Path $sr 'SoftwareDistribution'), (Join-Path (Join-Path $sr 'System32') 'catroot2'))
            try {
                foreach ($n in $svc) { $was[$n] = (& $c.Ops.Service $n 'state') }
                foreach ($n in $svc) { if ($was[$n] -eq 'Running') { & $c.Ops.Service $n 'stop' | Out-Null } }
                foreach ($dir in $dirs) {
                    $parent = Split-Path -Parent $dir
                    $names = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                    foreach ($old in (Get-ExpiredBackups -Names $names -Now $c.Now)) {
                        $full = Join-Path $parent $old
                        if (Test-SafeDeleteTarget -Path $full -AllowedRoots @($sr)) {
                            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
                            $msgs += ('Usunięto starą kopię: {0}' -f $old)
                        }
                    }
                }
                foreach ($from in $dirs) {
                    if (-not (Test-Path -LiteralPath $from)) { continue }
                    $to = '{0}.bak-{1}' -f $from, $stamp
                    if (Test-Path -LiteralPath $to) { $to = '{0}-{1}' -f $to, $c.Now.ToString('HHmmss', [System.Globalization.CultureInfo]::InvariantCulture) }
                    & $c.Ops.RenameItem $from $to
                    Add-UndoRecord -Dir $c.RunDir -Record @{ module = 'windows-update'; type = 'rename'; from = $from; to = $to }
                    $msgs += ('Zmieniono nazwę: {0} -> {1}' -f (Split-Path -Leaf $from), (Split-Path -Leaf $to))
                }
                $r = & $c.Runner 'netsh.exe' @('winsock', 'reset') 120
                $msgs += $(if ($r.ExitCode -eq 0) { 'Winsock zresetowany (zadziała po restarcie).' } else { ('netsh winsock reset: kod {0}.' -f $r.ExitCode) })
            }
            finally {
                foreach ($n in @($svc)[($svc.Count - 1)..0]) { if ($was[$n] -eq 'Running') { & $c.Ops.Service $n 'start' | Out-Null } }
            }
            $msgs += 'Sprawdź Windows Update; jeśli system prosi o restart, wykonaj go po wizycie.'
            return @{ Status = 'done'; Messages = $msgs }
        }
        Undo  = {
            param($c, $records)
            $svc = 'BITS', 'wuauserv', 'appidsvc', 'cryptsvc'
            $was = @{}
            $msgs = @()
            try {
                foreach ($n in $svc) { $was[$n] = (& $c.Ops.Service $n 'state') }
                foreach ($n in $svc) { if ($was[$n] -eq 'Running') { & $c.Ops.Service $n 'stop' | Out-Null } }
                foreach ($r in @($records | Where-Object { $_.module -eq 'windows-update' -and $_.type -eq 'rename' })) {
                    if (-not (Test-Path -LiteralPath $r.to)) { $msgs += ('Brak kopii {0}: pomijam.' -f (Split-Path -Leaf $r.to)); continue }
                    if (Test-Path -LiteralPath $r.from) {
                        if ((Get-DirectorySize -Path $r.from) -gt 1MB) { $msgs += ('Nowy folder {0} już ma dane: zostawiam kopię {1}.' -f (Split-Path -Leaf $r.from), (Split-Path -Leaf $r.to)); continue }
                        Remove-Item -LiteralPath $r.from -Recurse -Force
                    }
                    & $c.Ops.RenameItem $r.to $r.from
                    $msgs += ('Przywrócono {0}.' -f (Split-Path -Leaf $r.from))
                }
            }
            finally {
                foreach ($n in @($svc)[($svc.Count - 1)..0]) { if ($was[$n] -eq 'Running') { & $c.Ops.Service $n 'start' | Out-Null } }
            }
            return $msgs
        }
    }
}

function Get-StartupModule {
    return @{
        Name  = 'startup'
        Title = 'Autostart (wolny start)'
        Test  = { param($c) @($c.Audit.startup | Where-Object { $_.Disableable }).Count -gt 0 }
        Plan  = {
            param($c)
            $i = 0
            foreach ($it in (Get-StartupList -Audit $c.Audit)) {
                $i++
                $tag = if ($it.Disableable) { '' } else { ' [{0}]' -f $it.Reason }
                ('{0}. {1} ({2}, {3}){4}' -f $i, $it.Name, $it.Kind, $(if ($it.Publisher) { $it.Publisher } else { 'nieznany wydawca' }), $tag)
            }
            'Wyłączenie jest odwracalne (-Undo startup). Pozycje chronione nie zostaną ruszone.'
        }
        Apply = {
            param($c)
            $items = @(Get-StartupList -Audit $c.Audit)
            $sel = & $c.Prompt 'Podaj numery pozycji do wyłączenia (np. 1,3-5); Enter = żadna'
            $p = ConvertFrom-NumberSelection -Text ([string]$sel) -Max $items.Count
            if (-not $p.Valid) { return @{ Status = 'skipped'; Messages = @('Nieprawidłowy wybór: nic nie zmieniono.') } }
            if (@($p.Numbers).Count -eq 0) { return @{ Status = 'skipped'; Messages = @('Nic nie wybrano.') } }
            $msgs = @(); $done = 0
            foreach ($n in $p.Numbers) {
                $it = $items[$n - 1]
                if (-not $it.Disableable) { $msgs += ('Pominięto {0}: {1}.' -f $it.Name, $it.Reason); continue }
                try {
                    $rec = & $c.Ops.DisableStartup $it
                    $rec['module'] = 'startup'
                    Add-UndoRecord -Dir $c.RunDir -Record $rec
                    $done++
                    $msgs += ('Wyłączono: {0}' -f $it.Name)
                }
                catch { $msgs += ('Nie udało się wyłączyć {0}: {1}' -f $it.Name, $_.Exception.Message) }
            }
            return @{ Status = $(if ($done -gt 0) { 'done' } else { 'skipped' }); Messages = $msgs }
        }
        Undo  = {
            param($c, $records)
            $msgs = @()
            foreach ($r in @($records | Where-Object { $_.module -eq 'startup' })) {
                try { & $c.Ops.EnableStartup $r; $msgs += ('Przywrócono: {0}' -f $r.name) }
                catch { $msgs += ('Nie udało się przywrócić {0}: {1}' -f $r.name, $_.Exception.Message) }
            }
            return $msgs
        }
    }
}
