BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $src = Join-Path $script:root 'src'
    foreach ($m in 'WinResurect.psm1', 'DailyBackup.psm1', 'Repair.psm1') { Import-Module (Join-Path $src $m) -Force }
}

Describe 'status thresholds' {
    It 'rates free space: below 5% bad, below 15% warn, otherwise ok' {
        Get-SpaceStatus -FreeBytes 49 -TotalBytes 1000 | Should -Be 'bad'
        Get-SpaceStatus -FreeBytes 50 -TotalBytes 1000 | Should -Be 'warn'
        Get-SpaceStatus -FreeBytes 149 -TotalBytes 1000 | Should -Be 'warn'
        Get-SpaceStatus -FreeBytes 150 -TotalBytes 1000 | Should -Be 'ok'
        Get-SpaceStatus -FreeBytes 10 -TotalBytes 0 | Should -Be 'nodata'
    }

    It 'rates the average boot time: over 90 s warn, over 180 s bad, none means no data' {
        Get-BootStatus -Seconds @(60, 60) | Should -Be 'ok'
        Get-BootStatus -Seconds @(90, 90) | Should -Be 'ok'
        Get-BootStatus -Seconds @(91, 91) | Should -Be 'warn'
        Get-BootStatus -Seconds @(180) | Should -Be 'warn'
        Get-BootStatus -Seconds @(100, 300) | Should -Be 'bad'
        Get-BootStatus -Seconds @() | Should -Be 'nodata'
    }

    It 'rates physical disks by health, wear and unreadable sectors' {
        $ok = @{ Name = 'a'; Health = 'Healthy'; Wear = 10; Unreadable = 0 }
        Get-DiskHealthStatus -Disks @($ok) | Should -Be 'ok'
        Get-DiskHealthStatus -Disks @(@{ Name = 'a'; Health = 'Healthy'; Wear = 80; Unreadable = 0 }) | Should -Be 'ok'
        Get-DiskHealthStatus -Disks @(@{ Name = 'a'; Health = 'Healthy'; Wear = 81; Unreadable = 0 }) | Should -Be 'warn'
        Get-DiskHealthStatus -Disks @(@{ Name = 'a'; Health = 'Warning'; Wear = $null; Unreadable = $null }) | Should -Be 'warn'
        Get-DiskHealthStatus -Disks @(@{ Name = 'a'; Health = 'Unhealthy'; Wear = $null; Unreadable = $null }) | Should -Be 'bad'
        Get-DiskHealthStatus -Disks @(@{ Name = 'a'; Health = 'Healthy'; Wear = 5; Unreadable = 3 }) | Should -Be 'bad'
        Get-DiskHealthStatus -Disks @($ok, @{ Name = 'b'; Health = 'Unhealthy'; Wear = 1; Unreadable = 0 }) | Should -Be 'bad'
        Get-DiskHealthStatus -Disks @() | Should -Be 'nodata'
    }

    It 'rates updates: disabled service or repeated error is bad, old install or pending reboot is warn' {
        $types = @{ wuauserv = 'Manual'; BITS = 'Manual'; cryptsvc = 'Automatic' }
        Get-UpdateStatus -StartTypes $types -DaysSinceInstall 10 -PendingReboot $false -RepeatedErrorCode $null | Should -Be 'ok'
        Get-UpdateStatus -StartTypes $types -DaysSinceInstall 61 -PendingReboot $false -RepeatedErrorCode $null | Should -Be 'warn'
        Get-UpdateStatus -StartTypes $types -DaysSinceInstall 10 -PendingReboot $true -RepeatedErrorCode $null | Should -Be 'warn'
        Get-UpdateStatus -StartTypes @{ wuauserv = 'Disabled' } -DaysSinceInstall 10 -PendingReboot $false -RepeatedErrorCode $null | Should -Be 'bad'
        Get-UpdateStatus -StartTypes $types -DaysSinceInstall 10 -PendingReboot $false -RepeatedErrorCode '0x80070002' | Should -Be 'bad'
        Get-UpdateStatus -StartTypes $types -DaysSinceInstall $null -PendingReboot $false -RepeatedErrorCode $null | Should -Be 'nodata'
    }

    It 'rates memory and stability' {
        Get-MemoryStatus -TotalGB 16 -UsedPct 50 -CrashCount 0 | Should -Be 'ok'
        Get-MemoryStatus -TotalGB 4 -UsedPct 50 -CrashCount 0 | Should -Be 'warn'
        Get-MemoryStatus -TotalGB 16 -UsedPct 86 -CrashCount 0 | Should -Be 'warn'
        Get-MemoryStatus -TotalGB 16 -UsedPct 50 -CrashCount 1 | Should -Be 'warn'
        Get-MemoryStatus -TotalGB 16 -UsedPct 50 -CrashCount 2 | Should -Be 'bad'
    }

    It 'rates integrity from DISM and the SFC log' {
        Get-IntegrityStatus -Dism 'healthy' -SfcUnrepaired 0 | Should -Be 'ok'
        Get-IntegrityStatus -Dism 'repairable' -SfcUnrepaired 0 | Should -Be 'bad'
        Get-IntegrityStatus -Dism 'notrepairable' -SfcUnrepaired 0 | Should -Be 'bad'
        Get-IntegrityStatus -Dism 'healthy' -SfcUnrepaired 2 | Should -Be 'bad'
        Get-IntegrityStatus -Dism 'unknown' -SfcUnrepaired 0 | Should -Be 'nodata'
        Get-IntegrityStatus -Dism 'unknown' -SfcUnrepaired 1 | Should -Be 'bad'
    }
}

Describe 'output parsers' {
    It 'reads DISM /CheckHealth in English and Polish and never claims health for an unknown language' {
        ConvertFrom-DismCheckHealth -Text 'No component store corruption detected.' | Should -Be 'healthy'
        ConvertFrom-DismCheckHealth -Text 'Nie wykryto uszkodzenia magazynu składników.' | Should -Be 'healthy'
        ConvertFrom-DismCheckHealth -Text 'The component store is repairable.' | Should -Be 'repairable'
        ConvertFrom-DismCheckHealth -Text 'Magazyn składników można naprawić.' | Should -Be 'repairable'
        ConvertFrom-DismCheckHealth -Text 'The component store is not repairable.' | Should -Be 'notrepairable'
        ConvertFrom-DismCheckHealth -Text 'Magazyn składników nie można naprawić.' | Should -Be 'notrepairable'
        ConvertFrom-DismCheckHealth -Text 'Es wurde keine Beschädigung gefunden.' | Should -Be 'unknown'
        ConvertFrom-DismCheckHealth -Text '' | Should -Be 'unknown'
        ConvertFrom-DismCheckHealth -Text "N`0o c`0omponent store corruption detected." | Should -Be 'healthy'
    }

    It 'reads the component store recommendation' {
        ConvertFrom-AnalyzeComponentStore -Text "Component Store Cleanup Recommended : Yes" | Should -BeTrue
        ConvertFrom-AnalyzeComponentStore -Text "Component Store Cleanup Recommended : No" | Should -BeFalse
        ConvertFrom-AnalyzeComponentStore -Text "Zalecane czyszczenie magazynu składników : Tak" | Should -BeTrue
        ConvertFrom-AnalyzeComponentStore -Text "cos zupelnie innego" | Should -BeNullOrEmpty
    }

    It 'counts SFC failures only from the last transaction in CBS.log' {
        $lines = @(
            '2026-10-01 10:00:00, Info CSI [SR] Beginning Verify and Repair transaction',
            '2026-10-01 10:05:00, Info CSI [SR] Cannot repair member file [l:20]"x.dll" of Microsoft-Windows-X',
            '2026-10-01 10:06:00, Info CSI [SR] Verify complete',
            '2026-10-10 09:00:00, Info CSI [SR] Beginning Verify and Repair transaction',
            '2026-10-10 09:10:00, Info CSI [SR] Verify complete')
        (Get-SfcLogSummary -Lines $lines).Unrepaired | Should -Be 0
        (Get-SfcLogSummary -Lines ($lines[0..2])).Unrepaired | Should -Be 1
        (Get-SfcLogSummary -Lines @()).Unrepaired | Should -Be 0
    }
}

Describe 'cleanup candidates' {
    It 'sorts by size, drops empty ones and labels them in Polish' {
        $c = @(Get-CleanupCandidates -Sizes ([ordered]@{ 'temp-user' = 100; 'wu-download' = 5000; 'recycle' = 0; 'hibernate' = 900 }))
        $c.Count | Should -Be 3
        $c[0].id | Should -Be 'wu-download'
        $c[0].bytes | Should -Be 5000
        $c[2].id | Should -Be 'temp-user'
        $c[0].label | Should -Not -BeNullOrEmpty
    }
}

Describe 'finding summaries' {
    It 'has a Polish summary for every rated group and status' {
        foreach ($g in 'disk', 'space', 'boot', 'integrity', 'updates', 'memory') {
            foreach ($s in 'ok', 'warn', 'bad') {
                (Get-FindingSummary -Group $g -Status $s) | Should -Not -BeNullOrEmpty -Because "$g/$s"
            }
        }
    }
}

Describe 'report and diff' {
    BeforeAll {
        function New-TestAudit {
            param($Findings, $Candidates = @(), $Metrics = @{})
            $m = [ordered]@{ FreeBytes = $null; BootAvgSec = $null; StartupCount = $null; IntegrityStatus = $null }
            foreach ($k in $Metrics.Keys) { $m[$k] = $Metrics[$k] }
            [pscustomobject]@{ version = 1; computer = 'PC1'; generated = '2026-10-15T10:00:00'; findings = @($Findings); candidates = @($Candidates); startup = @(); componentStore = $null; notes = @(); metrics = $m }
        }
    }

    It 'puts bad before warn in the conclusions, at most five, and says so when all is well' {
        $f = @(
            (New-Finding -Group 'disk' -Status 'warn' -Summary 'w1'),
            (New-Finding -Group 'space' -Status 'bad' -Summary 'b1'),
            (New-Finding -Group 'boot' -Status 'ok' -Summary 'o1'),
            (New-Finding -Group 'updates' -Status 'nodata' -Summary 'Brak danych: x'))
        $r = Format-AuditReport -Audit (New-TestAudit -Findings $f)
        $r.IndexOf('b1') | Should -BeLessThan $r.IndexOf('w1')
        $r | Should -Match 'BRAK DANYCH'
        $clean = Format-AuditReport -Audit (New-TestAudit -Findings @((New-Finding -Group 'disk' -Status 'ok' -Summary 'o')))
        $clean | Should -Match 'Brak istotnych problemów'
        $many = 1..8 | ForEach-Object { New-Finding -Group 'disk' -Status 'bad' -Summary "problem$_" }
        $head = ((Format-AuditReport -Audit (New-TestAudit -Findings $many)) -split "`n" | Select-String 'problem' | Select-Object -First 6)
        @($head | Where-Object { $_.Line -match '^\s{2}\[' }).Count | Should -Be 5
    }

    It 'lists what can be reclaimed' {
        $r = Format-AuditReport -Audit (New-TestAudit -Findings @() -Candidates @([pscustomobject]@{ id = 'recycle'; label = 'Kosz'; bytes = 2147483648 }))
        $r | Should -Match 'Kosz'
        $r | Should -Match '2\.0 GB'
    }

    It 'compares before and after: reclaimed space, boot time, integrity' {
        $b = New-TestAudit -Findings @() -Metrics @{ FreeBytes = 10GB; BootAvgSec = 240; StartupCount = 30; IntegrityStatus = 'bad' }
        $a = New-TestAudit -Findings @() -Metrics @{ FreeBytes = 48GB; BootAvgSec = 95; StartupCount = 22; IntegrityStatus = 'ok' }
        $d = (Compare-Audits -Before $b -After $a) -join "`n"
        $d | Should -Match 'odzyskano 38\.0 GB'
        $d | Should -Match '240 s -> 95 s'
        $d | Should -Match '30 -> 22'
        $d | Should -Match 'ZŁY -> OK'
    }

    It 'skips the metrics that are missing on either side' {
        $b = New-TestAudit -Findings @()
        $a = New-TestAudit -Findings @() -Metrics @{ FreeBytes = 1GB }
        @(Compare-Audits -Before $b -After $a).Count | Should -Be 0
    }
}
