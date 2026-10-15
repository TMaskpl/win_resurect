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
