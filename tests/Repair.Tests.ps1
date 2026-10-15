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

Describe 'Invoke-NativeCommand' {
    BeforeAll { $script:pwsh = (Get-Process -Id $PID).Path }

    It 'returns the exit code and the output lines' {
        $r = Invoke-NativeCommand -Exe $script:pwsh -ArgList @('-NoProfile', '-Command', 'Write-Output hello; exit 3') -Quiet
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Contain 'hello'
        $r.TimedOut | Should -BeFalse
    }

    It 'stops waiting after the timeout and says so' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-NativeCommand -Exe $script:pwsh -ArgList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSec 3 -Quiet
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -Be -1
    }

    It 'treats a missing program as a failure instead of throwing' {
        $r = Invoke-NativeCommand -Exe 'definitely-not-a-program-xyz' -ArgList @() -Quiet
        $r.ExitCode | Should -Not -Be 0
    }

    It 'wraps the same behaviour in a runner scriptblock' {
        $runner = New-NativeRunner -Quiet
        $r = & $runner $script:pwsh @('-NoProfile', '-Command', 'exit 7') 0
        $r.ExitCode | Should -Be 7
    }
}

Describe 'cleanup roots' {
    It 'builds absolute paths from the system root and the users directory' {
        $r = Get-CleanupRoots -SystemRoot 'C:\Windows' -UsersDir (Join-Path $TestDrive 'nousers')
        $r['temp-win'] | Should -Contain 'C:\Windows\Temp'
        $r['wu-download'] | Should -Contain 'C:\Windows\SoftwareDistribution\Download'
        $r['dumps'] | Should -Contain 'C:\Windows\Minidump'
    }

    It 'falls back to C:\Windows when the system root is empty, never to a relative path' {
        $r = Get-CleanupRoots -SystemRoot '' -UsersDir (Join-Path $TestDrive 'nousers')
        foreach ($k in $r.Keys) { foreach ($p in $r[$k]) { $p | Should -Match '^[A-Za-z]:\\' } }
        $r['temp-win'] | Should -Contain 'C:\Windows\Temp'
    }

    It 'lists the Temp folder of every profile' {
        $users = Join-Path $TestDrive 'Users'
        New-Item -ItemType Directory -Force -Path (Join-Path $users 'Jan'), (Join-Path $users 'Ewa') | Out-Null
        $r = Get-CleanupRoots -SystemRoot 'C:\Windows' -UsersDir $users
        @($r['temp-user']).Count | Should -Be 2
        @($r['temp-user'])[0] | Should -Match 'AppData\\Local\\Temp$'
    }
}

Describe 'Get-DirectorySize' {
    It 'sums file sizes recursively and returns 0 for a missing folder' {
        $d = Join-Path $TestDrive 'sz'
        New-Item -ItemType Directory -Force -Path (Join-Path $d 'sub') | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $d 'a.bin'), (New-Object byte[] 1000))
        [System.IO.File]::WriteAllBytes((Join-Path $d 'sub/b.bin'), (New-Object byte[] 500))
        Get-DirectorySize -Path $d | Should -Be 1500
        Get-DirectorySize -Path (Join-Path $TestDrive 'nie-ma') | Should -Be 0
    }
}

Describe 'Test-ProtectedStartupItem' {
    It 'protects Microsoft entries, security software and folder shortcuts' {
        Test-ProtectedStartupItem -Item @{ Name = 'OneDrive'; Publisher = 'Microsoft Corporation'; Kind = 'run' } | Should -BeTrue
        Test-ProtectedStartupItem -Item @{ Name = 'ekrn'; Publisher = 'ESET, spol. s r.o.'; Kind = 'service' } | Should -BeTrue
        Test-ProtectedStartupItem -Item @{ Name = 'MBAMService'; Publisher = 'Malwarebytes'; Kind = 'service' } | Should -BeTrue
        Test-ProtectedStartupItem -Item @{ Name = 'skrot'; Publisher = ''; Kind = 'folder' } | Should -BeTrue
        Test-ProtectedStartupItem -Item @{ Name = 'Spotify'; Publisher = 'Spotify AB'; Kind = 'run' } | Should -BeFalse
    }
}

Describe 'Invoke-RepairAudit' {
    BeforeAll {
        function New-OkCollectors {
            @{
                disk       = { param($r) @{ Disks = @(@{ Name = 'SSD'; Health = 'Healthy'; Wear = 10; Unreadable = 0 }) } }
                space      = { param($r) @{ SystemDrive = 'C:'; Drives = @(@{ Drive = 'C:'; Free = 20GB; Total = 100GB }) } }
                candidates = { param($r) @{ Sizes = [ordered]@{ 'recycle' = 2GB; 'temp-user' = 1GB }; ComponentStoreCleanupRecommended = $true } }
                boot       = { param($r) @{ Seconds = @(100, 120) } }
                startup    = { param($r) @{ Items = @(@{ Name = 'A'; Kind = 'run'; Command = 'a.exe'; Publisher = 'X'; Location = 'HKLM'; Disableable = $true; Reason = '' }) } }
                integrity  = { param($r) @{ Dism = 'healthy'; SfcUnrepaired = 0 } }
                updates    = { param($r) @{ StartTypes = @{ wuauserv = 'Manual' }; DaysSinceInstall = 5; PendingReboot = $false; RepeatedErrorCode = $null } }
                memory     = { param($r) @{ TotalGB = 16; UsedPct = 40; CrashCount = 0; TopProcesses = @('chrome (1.0 GB)') } }
            }
        }
    }

    It 'turns the facts into rated findings, candidates, startup items and metrics' {
        $a = Invoke-RepairAudit -Collectors (New-OkCollectors) -Runner { } -Now ([datetime]'2026-10-15T10:00:00') -ComputerName 'PC1'
        $a.computer | Should -Be 'PC1'
        @($a.findings).Count | Should -Be 6
        (@($a.findings) | Where-Object group -eq 'boot').status | Should -Be 'warn'
        (@($a.findings) | Where-Object group -eq 'space').status | Should -Be 'ok'
        $a.candidates[0].id | Should -Be 'recycle'
        $a.componentStore | Should -BeTrue
        @($a.startup).Count | Should -Be 1
        (Get-AuditMetric -Audit $a -Name 'FreeBytes') | Should -Be 20GB
        (Get-AuditMetric -Audit $a -Name 'BootAvgSec') | Should -Be 110
        (Get-AuditMetric -Audit $a -Name 'StartupCount') | Should -Be 1
        (Get-AuditMetric -Audit $a -Name 'IntegrityStatus') | Should -Be 'ok'
    }

    It 'reports a collector that throws as no data with the reason, and still builds the rest' {
        $c = New-OkCollectors
        $c['disk'] = { param($r) throw 'Brak uprawnień' }
        $c['startup'] = { param($r) throw 'zadania niedostępne' }
        $a = Invoke-RepairAudit -Collectors $c -Runner { } -Now ([datetime]'2026-10-15T10:00:00') -ComputerName 'PC1'
        $d = @($a.findings) | Where-Object group -eq 'disk'
        $d.status | Should -Be 'nodata'
        $d.summary | Should -Match 'Brak uprawnień'
        @($a.findings).Count | Should -Be 6
        (@($a.notes) -join ' ') | Should -Match 'zadania niedostępne'
        (Get-AuditMetric -Audit $a -Name 'StartupCount') | Should -BeNullOrEmpty
    }

    It 'never throws with the real collectors, even where nothing is available (this machine is not Windows)' {
        { Invoke-RepairAudit -Runner { param($e, $a, $t) @{ ExitCode = -1; Output = @(); TimedOut = $false } } } | Should -Not -Throw
    }

    It 'can be serialised to JSON and rendered after a round trip' {
        $a = Invoke-RepairAudit -Collectors (New-OkCollectors) -Runner { } -Now ([datetime]'2026-10-15T10:00:00') -ComputerName 'PC1'
        $dir = Join-Path $TestDrive 'run1'
        $p = Save-AuditFile -Audit $a -Dir $dir -Name 'audit-before'
        Test-Path -LiteralPath $p | Should -BeTrue
        $back = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        (Format-AuditReport -Audit $back) | Should -Match 'Raport systemu: PC1'
        (Get-AuditMetric -Audit $back -Name 'FreeBytes') | Should -Be 20GB
    }
}

Describe 'New-RepairRunDir' {
    It 'creates a timestamped folder under repair' {
        $d = New-RepairRunDir -WorkDir (Join-Path $TestDrive 'wr') -Now ([datetime]'2026-10-15T10:11:12')
        Test-Path -LiteralPath $d | Should -BeTrue
        (Split-Path -Leaf $d) | Should -Be '20261015-101112'
        (Split-Path -Leaf (Split-Path -Parent $d)) | Should -Be 'repair'
    }
}

Describe 'audit entry script' {
    It 'runs end to end under StrictMode as a file, writes the report and exits 0' {
        $root = Split-Path $PSScriptRoot -Parent
        $pwsh = (Get-Process -Id $PID).Path
        $home2 = Join-Path $TestDrive 'wrhome'
        $env:WINRES_HOME = $home2
        try {
            $out = & $pwsh -NoProfile -File (Join-Path $root 'Get-WinAudit.ps1') 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        }
        finally { Remove-Item Env:WINRES_HOME -ErrorAction SilentlyContinue }
        @(Get-ChildItem -LiteralPath (Join-Path $home2 'repair') -Recurse -Filter 'raport.txt').Count | Should -Be 1
    }

    It 'is reachable through Invoke-Resurect.ps1 -Action audit' {
        $root = Split-Path $PSScriptRoot -Parent
        $pwsh = (Get-Process -Id $PID).Path
        $env:WINRES_HOME = (Join-Path $TestDrive 'wrhome2')
        try {
            & $pwsh -NoProfile -File (Join-Path $root 'Invoke-Resurect.ps1') -Action audit *> $null
            $LASTEXITCODE | Should -Be 0
        }
        finally { Remove-Item Env:WINRES_HOME -ErrorAction SilentlyContinue }
    }
}
