BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $src = Join-Path $script:root 'src'
    foreach ($m in 'WinResurect.psm1', 'DailyBackup.psm1', 'Repair.psm1') { Import-Module (Join-Path $src $m) -Force }

    function New-FakeRunner {
        param([object[]]$Responses = @())
        $log = New-Object System.Collections.ArrayList
        $resp = $Responses
        $runner = {
            param($Exe, $ArgList, $TimeoutSec = 0)
            $line = ('{0} {1}' -f $Exe, (@($ArgList) -join ' '))
            [void]$log.Add($line)
            foreach ($r in $resp) { if ($line -match $r.Match) { return @{ ExitCode = $r.ExitCode; Output = @($r.Output); TimedOut = [bool]$r.TimedOut } } }
            return @{ ExitCode = 0; Output = @(); TimedOut = $false }
        }.GetNewClosure()
        return @{ Runner = $runner; Calls = $log }
    }

    function New-FakeOps {
        param([hashtable]$States = @{}, [switch]$FailRename)
        $log = New-Object System.Collections.ArrayList
        $st = $States
        $fail = $FailRename.IsPresent
        $ops = @{
            Service         = {
                param($Name, $Action)
                if ($Action -eq 'state') { if ($st.ContainsKey($Name)) { return $st[$Name] } return $null }
                [void]$log.Add(('svc:{0}:{1}' -f $Action, $Name))
            }.GetNewClosure()
            ClearRecycleBin = { [void]$log.Add('recycle') }.GetNewClosure()
            RenameItem      = {
                param($From, $To)
                if ($fail) { throw 'rename failed' }
                [void]$log.Add(('rename:{0}->{1}' -f (Split-Path -Leaf $From), (Split-Path -Leaf $To)))
                Move-Item -LiteralPath $From -Destination $To
            }.GetNewClosure()
            DisableStartup  = { param($Item) [void]$log.Add('disable:' + $Item.Name); @{ kind = $Item.Kind; name = $Item.Name; location = $Item.Location } }.GetNewClosure()
            EnableStartup   = { param($Rec) [void]$log.Add('enable:' + $Rec.name) }.GetNewClosure()
        }
        return @{ Ops = $ops; Log = $log }
    }

    function New-TestAuditObject {
        param($Candidates = @(), $ComponentStore = $null, $Startup = @())
        [pscustomobject]@{ version = 1; computer = 'PC1'; generated = '2026-10-15T10:00:00'; findings = @(); candidates = @($Candidates); startup = @($Startup); componentStore = $ComponentStore; notes = @(); metrics = [ordered]@{ FreeBytes = $null; BootAvgSec = $null; StartupCount = $null; IntegrityStatus = $null } }
    }

    function New-TestContext {
        param($Audit, [hashtable]$Ops, [scriptblock]$Runner, [scriptblock]$Ask = { $true }, [scriptblock]$Prompt = { '' }, [hashtable]$Roots = @{}, [string]$SystemRoot = '', [string]$RunDir = '')
        New-RepairContext -Audit $Audit -Ops $Ops -Runner $Runner -Ask $Ask -Prompt $Prompt -Roots $Roots -SystemRoot $SystemRoot -RunDir $RunDir -Now ([datetime]'2026-10-15T10:00:00')
    }
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
    It 'returns 0 for a folder without files, also under StrictMode' {
        $d = Join-Path $TestDrive 'empty-sz'
        New-Item -ItemType Directory -Force -Path (Join-Path $d 'sub') | Out-Null
        Get-DirectorySize -Path $d | Should -Be 0
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

Describe 'Get-RepairPreflightErrors' {
    It 'refuses without admin, on battery, with a pending reboot or with too little free space' {
        $ok = @{ IsAdmin = $true; OnBattery = $false; SystemFreeBytes = 50GB; PendingReboot = $false }
        (Get-RepairPreflightErrors -Facts $ok).Errors.Count | Should -Be 0
        $bad = $ok.Clone(); $bad.IsAdmin = $false
        (Get-RepairPreflightErrors -Facts $bad).Errors | Should -Match 'administrator'
        $bad = $ok.Clone(); $bad.OnBattery = $true
        (Get-RepairPreflightErrors -Facts $bad).Errors | Should -Match 'baterii'
        $bad = $ok.Clone(); $bad.PendingReboot = $true
        (Get-RepairPreflightErrors -Facts $bad).Errors | Should -Match 'restart'
        $bad = $ok.Clone(); $bad.SystemFreeBytes = 1GB
        (Get-RepairPreflightErrors -Facts $bad).Errors | Should -Match 'miejsca'
    }
}

Describe 'Get-RepairFacts' {
    It 'never throws and always returns the four facts, even where Windows APIs are missing' {
        { Get-RepairFacts } | Should -Not -Throw
        $f = Get-RepairFacts
        foreach ($k in 'IsAdmin', 'OnBattery', 'SystemFreeBytes', 'PendingReboot') { $f.ContainsKey($k) | Should -BeTrue -Because $k }
    }
}

Describe 'Get-BackupGate' {
    BeforeAll {
        $script:now = [datetime]'2026-10-15T12:00:00'
        function New-Run($status, $hoursAgo) {
            [pscustomobject]@{ status = $status; last_success = $script:now.AddHours(-$hoursAgo).ToString('o') }
        }
    }
    It 'accepts a fresh daily backup' {
        $g = Get-BackupGate -LastRun (New-Run 'ok' 5) -Now $script:now
        $g.Allowed | Should -BeTrue
        $g.Basis | Should -Be 'daily'
    }
    It 'refuses a stale daily backup and a failed one' {
        (Get-BackupGate -LastRun (New-Run 'ok' 49) -Now $script:now).Allowed | Should -BeFalse
        (Get-BackupGate -LastRun (New-Run 'fail' 5) -Now $script:now).Allowed | Should -BeFalse
        (Get-BackupGate -LastRun $null -Now $script:now).Allowed | Should -BeFalse
    }
    It 'accepts a declared image up to 30 days old and nothing older or from the future' {
        (Get-BackupGate -LastRun $null -Now $script:now -ImageDate ([datetime]'2026-09-20')).Basis | Should -Be 'image'
        (Get-BackupGate -LastRun $null -Now $script:now -ImageDate ([datetime]'2026-09-10')).Allowed | Should -BeFalse
        (Get-BackupGate -LastRun $null -Now $script:now -ImageDate ([datetime]'2026-12-01')).Allowed | Should -BeFalse
    }
    It 'lets a written reason skip the check and records it, but not a blank one' {
        $g = Get-BackupGate -LastRun $null -Now $script:now -SkipReason 'klient ma kopię w chmurze'
        $g.Allowed | Should -BeTrue
        $g.Basis | Should -Be 'skip'
        $g.Message | Should -Match 'chmurze'
        (Get-BackupGate -LastRun $null -Now $script:now -SkipReason '   ').Allowed | Should -BeFalse
    }
    It 'tells the technician how to proceed when refusing' {
        (Get-BackupGate -LastRun $null -Now $script:now).Message | Should -Match 'ImageDate'
    }
}

Describe 'Test-SafeDeleteTarget' {
    BeforeAll { $script:allowed = @('C:\Windows\Temp', 'C:\Users\Jan\AppData\Local\Temp') }
    It 'accepts the allowed root and anything below it, ignoring case and slashes' {
        Test-SafeDeleteTarget -Path 'C:\Windows\Temp' -AllowedRoots $script:allowed | Should -BeTrue
        Test-SafeDeleteTarget -Path 'c:\windows\temp\sub\x.tmp' -AllowedRoots $script:allowed | Should -BeTrue
        Test-SafeDeleteTarget -Path 'C:/Windows/Temp/sub' -AllowedRoots $script:allowed | Should -BeTrue
    }
    It 'rejects empty, relative, parent-traversing and drive-root paths' {
        foreach ($p in '', '   ', '\Temp', 'Temp', '..\Temp', 'C:\Windows\Temp\..\System32', 'C:\', 'C:', '/') {
            Test-SafeDeleteTarget -Path $p -AllowedRoots $script:allowed | Should -BeFalse -Because "'$p'"
        }
    }
    It 'rejects look-alike siblings and paths above the root' {
        Test-SafeDeleteTarget -Path 'C:\Windows\Temporary' -AllowedRoots $script:allowed | Should -BeFalse
        Test-SafeDeleteTarget -Path 'C:\Windows' -AllowedRoots $script:allowed | Should -BeFalse
        Test-SafeDeleteTarget -Path 'C:\Windows\System32' -AllowedRoots $script:allowed | Should -BeFalse
    }
    It 'never treats a drive root or a blank entry as an allowed root' {
        Test-SafeDeleteTarget -Path 'C:\Windows\Temp' -AllowedRoots @('C:\', '', 'C:') | Should -BeFalse
        Test-SafeDeleteTarget -Path 'C:\Windows\Temp' -AllowedRoots @() | Should -BeFalse
    }
}

Describe 'Remove-FolderContents' {
    It 'deletes the contents but keeps the folder, and counts freed bytes' {
        $d = Join-Path $TestDrive 'rf1'
        New-Item -ItemType Directory -Force -Path (Join-Path $d 'sub') | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $d 'a.bin'), (New-Object byte[] 1000))
        [System.IO.File]::WriteAllBytes((Join-Path $d 'sub/b.bin'), (New-Object byte[] 500))
        $r = Remove-FolderContents -Path $d -AllowedRoots @($d)
        $r.FreedBytes | Should -Be 1500
        (Test-Path -LiteralPath $d) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $d -Force).Count | Should -Be 0
    }
    It 'keeps files newer than the age limit' {
        $d = Join-Path $TestDrive 'rf2'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $old = Join-Path $d 'old.tmp'; $new = Join-Path $d 'new.tmp'
        Set-Content -LiteralPath $old -Value 'x'; Set-Content -LiteralPath $new -Value 'x'
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-30)
        $r = Remove-FolderContents -Path $d -AllowedRoots @($d) -OlderThanDays 7
        (Test-Path -LiteralPath $old) | Should -BeFalse
        (Test-Path -LiteralPath $new) | Should -BeTrue
        $r.Skipped | Should -Be 1
    }
    It 'refuses a path outside the allowed roots without touching anything' {
        $d = Join-Path $TestDrive 'rf3'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'keep.txt') -Value 'x'
        { Remove-FolderContents -Path $d -AllowedRoots @((Join-Path $TestDrive 'inny')) } | Should -Throw '*Odmowa*'
        (Test-Path -LiteralPath (Join-Path $d 'keep.txt')) | Should -BeTrue
    }
    It 'does not follow links: data behind a link stays intact (and the linked folder is skipped)' -Skip:([Environment]::OSVersion.Platform -eq 'Win32NT') {
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'precious.txt') -Value 'x'
        $d = Join-Path $TestDrive 'rf4'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $d 'link') -Target $outside | Out-Null
        $nested = Join-Path $d 'wrap'
        New-Item -ItemType Directory -Force -Path $nested | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $nested 'link2') -Target $outside | Out-Null
        $r = Remove-FolderContents -Path $d -AllowedRoots @($d)
        (Test-Path -LiteralPath (Join-Path $outside 'precious.txt')) | Should -BeTrue
        $r.Skipped | Should -BeGreaterOrEqual 2
    }
}

Describe 'New-SafetyRestorePoint' {
    It 'reports success, failure and warnings from the creator' {
        (New-SafetyRestorePoint -Creator { @() }).Created | Should -BeTrue
        $w = New-SafetyRestorePoint -Creator { @('Punkt utworzono mniej niż 24 h temu') }
        $w.Created | Should -BeFalse
        $w.Message | Should -Match '24 h'
        $f = New-SafetyRestorePoint -Creator { throw 'Ochrona systemu wyłączona' }
        $f.Created | Should -BeFalse
        $f.Message | Should -Match 'wyłączona'
    }
}

Describe 'Invoke-RepairGate' {
    BeforeAll {
        $script:okFacts = @{ IsAdmin = $true; OnBattery = $false; SystemFreeBytes = 50GB; PendingReboot = $false }
        $script:now = [datetime]'2026-10-15T12:00:00'
        $script:fresh = [pscustomobject]@{ status = 'ok'; last_success = $script:now.AddHours(-2).ToString('o') }
    }
    It 'allows when preflight, backup and restore point are all fine' {
        $g = Invoke-RepairGate -Facts $script:okFacts -LastRun $script:fresh -Now $script:now -Creator { @() } -Ask { $true }
        $g.Allowed | Should -BeTrue
        $g.RestorePoint | Should -BeTrue
    }
    It 'stops at the first refusal and does not create a restore point' {
        $script:called = $false
        $noAdmin = $script:okFacts.Clone(); $noAdmin.IsAdmin = $false
        $g = Invoke-RepairGate -Facts $noAdmin -LastRun $script:fresh -Now $script:now -Creator { $script:called = $true; @() } -Ask { $true }
        $g.Allowed | Should -BeFalse
        $script:called | Should -BeFalse
        $g2 = Invoke-RepairGate -Facts $script:okFacts -LastRun $null -Now $script:now -Creator { $script:called = $true; @() } -Ask { $true }
        $g2.Allowed | Should -BeFalse
        $script:called | Should -BeFalse
    }
    It 'asks before continuing without a restore point and obeys the answer' {
        $yes = Invoke-RepairGate -Facts $script:okFacts -LastRun $script:fresh -Now $script:now -Creator { throw 'x' } -Ask { $true }
        $yes.Allowed | Should -BeTrue
        $yes.RestorePoint | Should -BeFalse
        $no = Invoke-RepairGate -Facts $script:okFacts -LastRun $script:fresh -Now $script:now -Creator { throw 'x' } -Ask { $false }
        $no.Allowed | Should -BeFalse
    }
    It 'carries the skip reason into the messages' {
        $g = Invoke-RepairGate -Facts $script:okFacts -LastRun $null -Now $script:now -SkipReason 'kopia w chmurze' -Creator { @() } -Ask { $true }
        $g.Allowed | Should -BeTrue
        ($g.Messages -join ' ') | Should -Match 'kopia w chmurze'
    }
}

Describe 'Invoke-RepairModule' {
    BeforeAll {
        function New-ProbeModule {
            param([bool]$Needed = $true, [string]$ApplyStatus = 'done', [switch]$Throw)
            $applied = New-Object System.Collections.ArrayList
            $m = @{
                Name = 'probe'; Title = 'Próbny'
                Test = { param($c) $Needed }.GetNewClosure()
                Plan = { param($c) @('krok 1', 'krok 2') }
                Apply = { param($c) [void]$applied.Add(1); if ($Throw) { throw 'kaboom' }; @{ Status = $ApplyStatus; Messages = @('zrobione') } }.GetNewClosure()
            }
            return @{ Module = $m; Applied = $applied }
        }
        $script:ctx = New-TestContext -Audit (New-TestAuditObject) -Ops @{} -Runner { }
    }
    It 'skips a module that has nothing to do without asking' {
        $p = New-ProbeModule -Needed $false
        $r = Invoke-RepairModule -Module $p.Module -Context $script:ctx
        $r.Status | Should -Be 'skipped'
        $p.Applied.Count | Should -Be 0
    }
    It 'shows the plan, asks, and does not apply when declined' {
        $p = New-ProbeModule
        $asked = New-Object System.Collections.ArrayList
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops @{} -Runner { } -Ask ({ param($q) [void]$asked.Add($q); $false }.GetNewClosure())
        $r = Invoke-RepairModule -Module $p.Module -Context $c
        $r.Status | Should -Be 'declined'
        $p.Applied.Count | Should -Be 0
        $asked[0] | Should -Match 'krok 1'
        $asked[0] | Should -Match 'Próbny'
    }
    It 'applies after consent and returns the status of Apply' {
        $p = New-ProbeModule
        $r = Invoke-RepairModule -Module $p.Module -Context $script:ctx
        $r.Status | Should -Be 'done'
        $r.Messages | Should -Contain 'zrobione'
    }
    It 'turns an exception into a failure with a message instead of throwing' {
        $p = New-ProbeModule -Throw
        $r = Invoke-RepairModule -Module $p.Module -Context $script:ctx
        $r.Status | Should -Be 'fail'
        ($r.Messages -join ' ') | Should -Match 'kaboom'
    }
}

Describe 'New-RepairContext' {
    It 'defaults the system root to C:\Windows when the given one is empty or relative' {
        (New-RepairContext -Audit $null -RunDir '' -SystemRoot '').SystemRoot | Should -Be 'C:\Windows'
        (New-RepairContext -Audit $null -RunDir '' -SystemRoot 'Windows').SystemRoot | Should -Be 'C:\Windows'
        (New-RepairContext -Audit $null -RunDir '' -SystemRoot 'D:\Win\').SystemRoot | Should -Be 'D:\Win'
    }
    It 'builds the cleanup roots from the system root unless roots are injected' {
        (New-RepairContext -Audit $null -RunDir '' -SystemRoot 'D:\Win').Roots['temp-win'] | Should -Contain 'D:\Win\Temp'
    }
}

Describe 'cleanup module' {
    BeforeEach {
        $base = Join-Path $TestDrive ('c' + [guid]::NewGuid().ToString('N'))
        $script:wu = Join-Path $base 'wu'
        $script:tw = Join-Path $base 'tw'
        New-Item -ItemType Directory -Force -Path $script:wu, $script:tw | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:wu 'a.cab'), (New-Object byte[] 2000))
        [System.IO.File]::WriteAllBytes((Join-Path $script:tw 'old.tmp'), (New-Object byte[] 100))
        [System.IO.File]::WriteAllBytes((Join-Path $script:tw 'new.tmp'), (New-Object byte[] 100))
        (Get-Item (Join-Path $script:tw 'old.tmp')).LastWriteTime = [datetime]'2026-09-01'
        (Get-Item (Join-Path $script:tw 'new.tmp')).LastWriteTime = [datetime]'2026-10-14'
        $script:roots = @{ 'temp-user' = @(); 'temp-win' = @($script:tw); 'wu-download' = @($script:wu); 'dumps' = @() }
        $script:cands = @(
            [pscustomobject]@{ id = 'wu-download'; label = 'Pobrane aktualizacje'; bytes = 2000 },
            [pscustomobject]@{ id = 'temp-win'; label = 'Temp systemu'; bytes = 200 },
            [pscustomobject]@{ id = 'recycle'; label = 'Kosz'; bytes = 500 },
            [pscustomobject]@{ id = 'hibernate'; label = 'Hibernacja'; bytes = 900 })
    }

    It 'has nothing to do without candidates or a component store recommendation' {
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops @{} -Runner { }
        (& (Get-CleanupModule).Test $c) | Should -BeFalse
        $c2 = New-TestContext -Audit (New-TestAuditObject -ComponentStore $true) -Ops @{} -Runner { }
        (& (Get-CleanupModule).Test $c2) | Should -BeTrue
    }

    It 'empties the update cache, removes only temp files older than 7 days, and reports freed space' {
        $ops = New-FakeOps -States @{ wuauserv = 'Running' }
        $fr = New-FakeRunner
        $c = New-TestContext -Audit (New-TestAuditObject -Candidates $script:cands) -Ops $ops.Ops -Runner $fr.Runner -Roots $script:roots -Ask { $false }
        $r = & (Get-CleanupModule).Apply $c
        $r.Status | Should -Be 'done'
        @(Get-ChildItem -LiteralPath $script:wu -Force).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:tw 'old.tmp')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:tw 'new.tmp')) | Should -BeTrue
        ($r.Messages -join ' ') | Should -Match 'Zwolniono'
    }

    It 'stops the update service for the cache and starts it again afterwards' {
        $ops = New-FakeOps -States @{ wuauserv = 'Running' }
        $c = New-TestContext -Audit (New-TestAuditObject -Candidates $script:cands) -Ops $ops.Ops -Runner (New-FakeRunner).Runner -Roots $script:roots -Ask { $false }
        & (Get-CleanupModule).Apply $c | Out-Null
        $ops.Log.IndexOf('svc:stop:wuauserv') | Should -BeGreaterOrEqual 0
        $ops.Log.IndexOf('svc:start:wuauserv') | Should -BeGreaterThan $ops.Log.IndexOf('svc:stop:wuauserv')
    }

    It 'does not start a service that was not running' {
        $ops = New-FakeOps -States @{ wuauserv = 'Stopped' }
        $c = New-TestContext -Audit (New-TestAuditObject -Candidates $script:cands) -Ops $ops.Ops -Runner (New-FakeRunner).Runner -Roots $script:roots -Ask { $false }
        & (Get-CleanupModule).Apply $c | Out-Null
        $ops.Log | Should -Not -Contain 'svc:start:wuauserv'
    }

    It 'asks separately about the recycle bin and hibernation and obeys a no' {
        $ops = New-FakeOps
        $fr = New-FakeRunner
        $c = New-TestContext -Audit (New-TestAuditObject -Candidates $script:cands) -Ops $ops.Ops -Runner $fr.Runner -Roots $script:roots -Ask { $false }
        & (Get-CleanupModule).Apply $c | Out-Null
        $ops.Log | Should -Not -Contain 'recycle'
        ($fr.Calls -join "`n") | Should -Not -Match 'powercfg'
    }

    It 'empties the recycle bin and turns hibernation off after a yes' {
        $ops = New-FakeOps
        $fr = New-FakeRunner
        $c = New-TestContext -Audit (New-TestAuditObject -Candidates $script:cands) -Ops $ops.Ops -Runner $fr.Runner -Roots $script:roots -Ask { $true }
        & (Get-CleanupModule).Apply $c | Out-Null
        $ops.Log | Should -Contain 'recycle'
        ($fr.Calls -join "`n") | Should -Match 'powercfg.exe -h off'
    }

    It 'cleans the component store without ResetBase when recommended' {
        $fr = New-FakeRunner
        $c = New-TestContext -Audit (New-TestAuditObject -ComponentStore $true) -Ops (New-FakeOps).Ops -Runner $fr.Runner -Roots $script:roots -Ask { $false }
        & (Get-CleanupModule).Apply $c | Out-Null
        ($fr.Calls -join "`n") | Should -Match '/StartComponentCleanup'
        ($fr.Calls -join "`n") | Should -Not -Match 'ResetBase'
    }

    It 'fails closed on an unsafe root: nothing is deleted, the service is started again' {
        $ops = New-FakeOps -States @{ wuauserv = 'Running' }
        $bad = @{ 'temp-user' = @(); 'temp-win' = @(); 'wu-download' = @('C:\'); 'dumps' = @() }
        $c = New-TestContext -Audit (New-TestAuditObject -Candidates $script:cands) -Ops $ops.Ops -Runner (New-FakeRunner).Runner -Roots $bad -Ask { $true }
        $r = Invoke-RepairModule -Module (Get-CleanupModule) -Context $c
        $r.Status | Should -Be 'fail'
        (Test-Path -LiteralPath (Join-Path $script:wu 'a.cab')) | Should -BeTrue
        $ops.Log | Should -Contain 'svc:start:wuauserv'
    }
}

Describe 'system-repair parsing' {
    It 'reads sfc output in English and Polish, including UTF-16 style NUL padding' {
        ConvertFrom-SfcOutput -Text 'Windows Resource Protection did not find any integrity violations.' | Should -Be 'clean'
        ConvertFrom-SfcOutput -Text 'Ochrona zasobów systemu Windows nie wykryła żadnych naruszeń integralności.' | Should -Be 'clean'
        ConvertFrom-SfcOutput -Text 'Windows Resource Protection found corrupt files and successfully repaired them.' | Should -Be 'repaired'
        ConvertFrom-SfcOutput -Text 'Ochrona zasobów systemu Windows znalazła uszkodzone pliki i pomyślnie je naprawiła.' | Should -Be 'repaired'
        ConvertFrom-SfcOutput -Text 'Windows Resource Protection found corrupt files but was unable to fix some of them.' | Should -Be 'unrepairable'
        ConvertFrom-SfcOutput -Text 'Ochrona zasobów systemu Windows znalazła uszkodzone pliki, ale nie może naprawić niektórych z nich.' | Should -Be 'unrepairable'
        ConvertFrom-SfcOutput -Text "D`0i`0d`0 `0n`0o`0t`0 `0f`0i`0n`0d`0 `0a`0n`0y`0 `0i`0n`0t`0e`0g`0r`0i`0t`0y`0 `0v`0i`0o`0l`0a`0t`0i`0o`0n`0s`0" | Should -Be 'clean'
        ConvertFrom-SfcOutput -Text 'Der Windows-Ressourcenschutz hat keine Integritätsverletzungen gefunden.' | Should -Be 'unknown'
        ConvertFrom-SfcOutput -Text '' | Should -Be 'unknown'
    }
}

Describe 'Get-SystemRepairVerdict' {
    BeforeAll {
        function New-Step($exit, $text, $timedOut = $false) { @{ ExitCode = $exit; Output = @($text); TimedOut = $timedOut } }
        $script:okRestore = New-Step 0 'The restore operation completed successfully.'
        $script:okSfc = New-Step 0 'Windows Resource Protection did not find any integrity violations.'
        $script:okCheck = New-Step 0 'No component store corruption detected.'
    }
    It 'is done when everything is clean' {
        (Get-SystemRepairVerdict -Restore $script:okRestore -Sfc $script:okSfc -Check $script:okCheck).Status | Should -Be 'done'
    }
    It 'fails and advises an ISO source when DISM RestoreHealth fails' {
        $v = Get-SystemRepairVerdict -Restore (New-Step 1 'Error: 0x800f081f') -Sfc $script:okSfc -Check $script:okCheck
        $v.Status | Should -Be 'fail'
        ($v.Messages -join ' ') | Should -Match 'Source'
    }
    It 'fails when sfc cannot repair some files, and when the component store is still damaged' {
        (Get-SystemRepairVerdict -Restore $script:okRestore -Sfc (New-Step 0 'found corrupt files but was unable to fix some of them') -Check $script:okCheck).Status | Should -Be 'fail'
        (Get-SystemRepairVerdict -Restore $script:okRestore -Sfc $script:okSfc -Check (New-Step 0 'The component store is repairable.')).Status | Should -Be 'fail'
    }
    It 'fails on a timeout and names the step' {
        $v = Get-SystemRepairVerdict -Restore (New-Step -1 '' $true) -Sfc $script:okSfc -Check $script:okCheck
        $v.Status | Should -Be 'fail'
        ($v.Messages -join ' ') | Should -Match 'RestoreHealth.*limit czasu'
    }
    It 'does not claim success for an unrecognised language: done, but says it could not read the result' {
        $v = Get-SystemRepairVerdict -Restore $script:okRestore -Sfc (New-Step 0 'Der Windows-Ressourcenschutz hat nichts gefunden.') -Check (New-Step 0 'Keine Beschädigung.')
        $v.Status | Should -Be 'done'
        ($v.Messages -join ' ') | Should -Match 'nie rozpoznano'
    }
}

Describe 'system-repair module' {
    It 'runs DISM RestoreHealth, sfc and DISM CheckHealth in that order with the 60 min limit' {
        $fr = New-FakeRunner
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops (New-FakeOps).Ops -Runner $fr.Runner
        (& (Get-SystemRepairModule).Apply $c) | Out-Null
        $fr.Calls.Count | Should -Be 3
        $fr.Calls[0] | Should -Match 'dism.exe /Online /Cleanup-Image /RestoreHealth'
        $fr.Calls[1] | Should -Match 'sfc.exe /scannow'
        $fr.Calls[2] | Should -Match 'dism.exe /Online /Cleanup-Image /CheckHealth'
    }
    It 'is always offered' {
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops (New-FakeOps).Ops -Runner { }
        (& (Get-SystemRepairModule).Test $c) | Should -BeTrue
    }
}

Describe 'undo store' {
    It 'appends records, reads them back and marks a module as undone' {
        $d = Join-Path $TestDrive 'u1'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        @(Read-UndoRecords -Dir $d).Count | Should -Be 0
        Add-UndoRecord -Dir $d -Record @{ module = 'startup'; kind = 'run'; name = 'A' }
        Add-UndoRecord -Dir $d -Record @{ module = 'windows-update'; type = 'rename'; from = 'x'; to = 'y' }
        $all = @(Read-UndoRecords -Dir $d)
        $all.Count | Should -Be 2
        $all[0].name | Should -Be 'A'
        Set-UndoDone -Dir $d -Module 'startup'
        $after = @(Read-UndoRecords -Dir $d)
        $after[0].undone | Should -BeTrue
        $after[1].PSObject.Properties['undone'] | Should -BeNullOrEmpty
    }
    It 'survives a damaged file' {
        $d = Join-Path $TestDrive 'u2'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Set-Content -LiteralPath (Get-UndoPath -Dir $d) -Value '{ not json'
        @(Read-UndoRecords -Dir $d).Count | Should -Be 0
    }
    It 'finds the newest run folder that still has something to undo for a module' {
        $w = Join-Path $TestDrive 'u3'
        foreach ($n in '20261001-100000', '20261005-100000', '20261010-100000') { New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $w 'repair') $n) | Out-Null }
        Add-UndoRecord -Dir (Join-Path (Join-Path $w 'repair') '20261005-100000') -Record @{ module = 'startup'; name = 'A' }
        Add-UndoRecord -Dir (Join-Path (Join-Path $w 'repair') '20261010-100000') -Record @{ module = 'windows-update'; type = 'rename' }
        (Split-Path -Leaf (Get-LatestUndoDir -WorkDir $w -Module 'startup')) | Should -Be '20261005-100000'
        Set-UndoDone -Dir (Join-Path (Join-Path $w 'repair') '20261005-100000') -Module 'startup'
        Get-LatestUndoDir -WorkDir $w -Module 'startup' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-NumberSelection' {
    It 'parses numbers and ranges into a sorted unique list' {
        $r = ConvertFrom-NumberSelection -Text '3, 1-2,2' -Max 5
        $r.Valid | Should -BeTrue
        ($r.Numbers -join ',') | Should -Be '1,2,3'
    }
    It 'treats an empty answer as a valid choice of nothing' {
        $r = ConvertFrom-NumberSelection -Text '  ' -Max 5
        $r.Valid | Should -BeTrue
        @($r.Numbers).Count | Should -Be 0
    }
    It 'rejects every kind of garbage as a whole' {
        foreach ($t in '0', '99', '6', 'abc', '1,,3', '3-1', '1-', '-2', '1;2', '1.5', '99999999999') {
            (ConvertFrom-NumberSelection -Text $t -Max 5).Valid | Should -BeFalse -Because "'$t'"
        }
    }
}

Describe 'Get-ExpiredBackups' {
    It 'returns only backup folders older than the limit and ignores other names' {
        $names = @('SoftwareDistribution.bak-20260901', 'SoftwareDistribution.bak-20261010', 'catroot2.bak-20260920-101500', 'SoftwareDistribution', 'inne.bak-20200101', 'catroot2.bak-zle')
        $e = @(Get-ExpiredBackups -Names $names -Now ([datetime]'2026-10-15'))
        $e | Should -Contain 'SoftwareDistribution.bak-20260901'
        $e | Should -Contain 'catroot2.bak-20260920-101500'
        $e.Count | Should -Be 2
    }
}

Describe 'windows-update module' {
    BeforeEach {
        $script:sr = Join-Path $TestDrive ('w' + [guid]::NewGuid().ToString('N'))
        $script:sd = Join-Path $script:sr 'SoftwareDistribution'
        $script:cr = Join-Path (Join-Path $script:sr 'System32') 'catroot2'
        New-Item -ItemType Directory -Force -Path $script:sd, $script:cr | Out-Null
        Set-Content -LiteralPath (Join-Path $script:sd 'x.dat') -Value 'x'
        $script:run = Join-Path $TestDrive ('r' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:run | Out-Null
        $script:allRunning = @{ BITS = 'Running'; wuauserv = 'Running'; appidsvc = 'Running'; cryptsvc = 'Running' }
    }

    It 'stops the services, renames the two folders (not deletes), resets winsock and starts the services again' {
        $ops = New-FakeOps -States $script:allRunning
        $fr = New-FakeRunner
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops $ops.Ops -Runner $fr.Runner -SystemRoot $script:sr -RunDir $script:run
        $r = & (Get-WindowsUpdateModule).Apply $c
        $r.Status | Should -Be 'done'
        (Test-Path -LiteralPath (Join-Path $script:sd 'x.dat')) | Should -BeFalse
        (Test-Path -LiteralPath ($script:sd + '.bak-20261015')) | Should -BeTrue
        (Test-Path -LiteralPath ($script:cr + '.bak-20261015')) | Should -BeTrue
        ($fr.Calls -join "`n") | Should -Match 'netsh.exe winsock reset'
        foreach ($n in 'BITS', 'wuauserv', 'appidsvc', 'cryptsvc') {
            $ops.Log | Should -Contain "svc:stop:$n"
            $ops.Log | Should -Contain "svc:start:$n"
        }
        $firstRename = $ops.Log | Where-Object { $_ -like 'rename:*' } | Select-Object -First 1
        $ops.Log.IndexOf('svc:stop:wuauserv') | Should -BeLessThan $ops.Log.IndexOf($firstRename)
        @(Read-UndoRecords -Dir $script:run).Count | Should -Be 2
    }

    It 'starts the services again even when the rename throws, and the module reports a failure' {
        $ops = New-FakeOps -States $script:allRunning -FailRename
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops $ops.Ops -Runner (New-FakeRunner).Runner -SystemRoot $script:sr -RunDir $script:run
        $r = Invoke-RepairModule -Module (Get-WindowsUpdateModule) -Context $c
        $r.Status | Should -Be 'fail'
        foreach ($n in 'BITS', 'wuauserv', 'appidsvc', 'cryptsvc') { $ops.Log | Should -Contain "svc:start:$n" }
        (Test-Path -LiteralPath (Join-Path $script:sd 'x.dat')) | Should -BeTrue
    }

    It 'does not start services that were not running' {
        $ops = New-FakeOps -States @{ BITS = 'Stopped'; wuauserv = 'Running'; appidsvc = 'Stopped'; cryptsvc = 'Running' }
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops $ops.Ops -Runner (New-FakeRunner).Runner -SystemRoot $script:sr -RunDir $script:run
        & (Get-WindowsUpdateModule).Apply $c | Out-Null
        $ops.Log | Should -Not -Contain 'svc:start:BITS'
        $ops.Log | Should -Contain 'svc:start:wuauserv'
    }

    It 'removes backup folders older than 14 days but keeps recent ones' {
        $old = $script:sd + '.bak-20260901'
        $recent = $script:cr + '.bak-20261010'
        New-Item -ItemType Directory -Force -Path $old, $recent | Out-Null
        $ops = New-FakeOps -States $script:allRunning
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops $ops.Ops -Runner (New-FakeRunner).Runner -SystemRoot $script:sr -RunDir $script:run
        & (Get-WindowsUpdateModule).Apply $c | Out-Null
        (Test-Path -LiteralPath $old) | Should -BeFalse
        (Test-Path -LiteralPath $recent) | Should -BeTrue
    }

    It 'undoes the rename when the new folder is still small, and leaves the backup when it already has data' {
        $ops = New-FakeOps -States $script:allRunning
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops $ops.Ops -Runner (New-FakeRunner).Runner -SystemRoot $script:sr -RunDir $script:run
        & (Get-WindowsUpdateModule).Apply $c | Out-Null
        New-Item -ItemType Directory -Force -Path $script:sd | Out-Null          # Windows odtworzył pusty folder
        New-Item -ItemType Directory -Force -Path $script:cr | Out-Null          # ten już ma dane
        [System.IO.File]::WriteAllBytes((Join-Path $script:cr 'big.bin'), (New-Object byte[] (2MB)))
        $msgs = & (Get-WindowsUpdateModule).Undo $c @(Read-UndoRecords -Dir $script:run)
        (Test-Path -LiteralPath (Join-Path $script:sd 'x.dat')) | Should -BeTrue
        (Test-Path -LiteralPath ($script:cr + '.bak-20261015')) | Should -BeTrue
        ($msgs -join ' ') | Should -Match 'już ma dane'
    }

    It 'is always offered' {
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops (New-FakeOps).Ops -Runner { }
        (& (Get-WindowsUpdateModule).Test $c) | Should -BeTrue
    }
}

Describe 'startup module' {
    BeforeAll {
        $script:items = @(
            @{ Name = 'Spotify'; Kind = 'run'; Command = 's.exe'; Publisher = 'Spotify AB'; Location = 'HKCU:\Run'; Disableable = $true; Reason = '' },
            @{ Name = 'Defender'; Kind = 'service'; Command = 'd.exe'; Publisher = 'Microsoft'; Location = 'service'; Disableable = $false; Reason = 'chronione' },
            @{ Name = 'Adobe'; Kind = 'task'; Command = 'a.exe'; Publisher = 'Adobe'; Location = '\'; Disableable = $true; Reason = '' })
    }
    BeforeEach {
        $script:run = Join-Path $TestDrive ('s' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:run | Out-Null
    }

    It 'lists items sorted by name so numbers shown and numbers chosen agree' {
        (Get-StartupList -Audit (New-TestAuditObject -Startup $script:items) | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Adobe,Defender,Spotify'
    }

    It 'is offered only when something can be disabled' {
        $none = @(@{ Name = 'D'; Kind = 'service'; Command = ''; Publisher = 'Microsoft'; Location = 's'; Disableable = $false; Reason = 'chronione' })
        (& (Get-StartupModule).Test (New-TestContext -Audit (New-TestAuditObject -Startup $none) -Ops @{} -Runner { })) | Should -BeFalse
        (& (Get-StartupModule).Test (New-TestContext -Audit (New-TestAuditObject -Startup $script:items) -Ops @{} -Runner { })) | Should -BeTrue
    }

    It 'disables exactly the chosen items, refuses protected ones and records undo data' {
        $ops = New-FakeOps
        $c = New-TestContext -Audit (New-TestAuditObject -Startup $script:items) -Ops $ops.Ops -Runner { } -Prompt { '1-3' } -RunDir $script:run
        $r = & (Get-StartupModule).Apply $c
        $r.Status | Should -Be 'done'
        $ops.Log | Should -Contain 'disable:Adobe'
        $ops.Log | Should -Contain 'disable:Spotify'
        $ops.Log | Should -Not -Contain 'disable:Defender'
        ($r.Messages -join ' ') | Should -Match 'Defender.*chronione'
        $rec = @(Read-UndoRecords -Dir $script:run)
        $rec.Count | Should -Be 2
        $rec[0].module | Should -Be 'startup'
    }

    It 'changes nothing for garbage, out-of-range or empty answers' {
        foreach ($answer in '0', '99', 'abc', '1,,3', '3-1', '') {
            $ops = New-FakeOps
            $a = $answer
            $c = New-TestContext -Audit (New-TestAuditObject -Startup $script:items) -Ops $ops.Ops -Runner { } -Prompt ({ $a }.GetNewClosure()) -RunDir $script:run
            $r = & (Get-StartupModule).Apply $c
            $r.Status | Should -Be 'skipped' -Because "'$answer'"
            $ops.Log.Count | Should -Be 0 -Because "'$answer'"
        }
    }

    It 'reports a failing disable and keeps going' {
        $ops = New-FakeOps
        $ops.Ops['DisableStartup'] = { param($Item) if ($Item.Name -eq 'Adobe') { throw 'brak dostępu' }; @{ kind = $Item.Kind; name = $Item.Name; location = $Item.Location } }
        $c = New-TestContext -Audit (New-TestAuditObject -Startup $script:items) -Ops $ops.Ops -Runner { } -Prompt { '1,3' } -RunDir $script:run
        $r = & (Get-StartupModule).Apply $c
        ($r.Messages -join ' ') | Should -Match 'Adobe.*brak dostępu'
        @(Read-UndoRecords -Dir $script:run).Count | Should -Be 1
    }

    It 'undo re-enables every record' {
        $ops = New-FakeOps
        $c = New-TestContext -Audit (New-TestAuditObject) -Ops $ops.Ops -Runner { }
        $recs = @([pscustomobject]@{ module = 'startup'; kind = 'run'; name = 'Spotify'; location = 'HKCU:\Run'; value = 's.exe' }, [pscustomobject]@{ module = 'startup'; kind = 'task'; name = 'Adobe'; location = '\' })
        $msgs = & (Get-StartupModule).Undo $c $recs
        $ops.Log | Should -Contain 'enable:Spotify'
        $ops.Log | Should -Contain 'enable:Adobe'
        @($msgs).Count | Should -BeGreaterThan 0
    }
}

Describe 'module selection' {
    It 'returns all modules in the canonical order when no names are given' {
        $r = Resolve-RepairModules -Names @()
        $r.Valid | Should -BeTrue
        ($r.Modules | ForEach-Object { $_.Name }) -join ',' | Should -Be 'system-repair,windows-update,cleanup,startup'
    }
    It 'keeps the canonical order whatever order the names come in' {
        $r = Resolve-RepairModules -Names @('startup', 'cleanup')
        ($r.Modules | ForEach-Object { $_.Name }) -join ',' | Should -Be 'cleanup,startup'
    }
    It 'rejects an unknown name and lists the valid ones' {
        $r = Resolve-RepairModules -Names @('cleanup', 'bogus')
        $r.Valid | Should -BeFalse
        $r.Error | Should -Match 'bogus'
        $r.Error | Should -Match 'system-repair'
    }
}

Describe 'Format-RepairSummary' {
    It 'shows the safety basis, every module outcome in Polish and the before/after lines' {
        $gate = @{ Allowed = $true; Messages = @('Świeża kopia codzienna.', 'Utworzono punkt przywracania.') }
        $res = @(@{ Name = 'cleanup'; Status = 'done'; Messages = @('Zwolniono ok. 3.0 GB') }, @{ Name = 'startup'; Status = 'declined'; Messages = @('Pominięte') }, @{ Name = 'windows-update'; Status = 'fail'; Messages = @('Błąd: x') })
        $t = Format-RepairSummary -Gate $gate -Results $res -Diff @('Wolne miejsce: 10.0 GB -> 13.0 GB (odzyskano 3.0 GB)')
        $t | Should -Match 'Świeża kopia codzienna'
        $t | Should -Match 'cleanup: wykonano'
        $t | Should -Match 'startup: odrzucono'
        $t | Should -Match 'windows-update: BŁĄD'
        $t | Should -Match 'odzyskano 3\.0 GB'
    }
}

Describe 'Invoke-RepairRun' {
    BeforeAll {
        function New-RunCollectors {
            @{
                disk       = { param($r) @{ Disks = @(@{ Name = 'SSD'; Health = 'Healthy'; Wear = 1; Unreadable = 0 }) } }
                space      = { param($r) @{ SystemDrive = 'C:'; Drives = @(@{ Drive = 'C:'; Free = 20GB; Total = 100GB }) } }
                candidates = { param($r) @{ Sizes = [ordered]@{ 'recycle' = 1000 }; ComponentStoreCleanupRecommended = $false } }
                boot       = { param($r) @{ Seconds = @(60) } }
                startup    = { param($r) @{ Items = @() } }
                integrity  = { param($r) @{ Dism = 'healthy'; SfcUnrepaired = 0 } }
                updates    = { param($r) @{ StartTypes = @{}; DaysSinceInstall = 1; PendingReboot = $false; RepeatedErrorCode = $null } }
                memory     = { param($r) @{ TotalGB = 16; UsedPct = 10; CrashCount = 0; TopProcesses = @() } }
            }
        }
        $script:okFacts = @{ IsAdmin = $true; OnBattery = $false; SystemFreeBytes = 50GB; PendingReboot = $false }
        $script:fresh = [pscustomobject]@{ status = 'ok'; last_success = (Get-Date).AddHours(-1).ToString('o') }
        $script:said = New-Object System.Collections.ArrayList
    }

    It 'rejects an unknown module before touching anything' {
        $w = Join-Path $TestDrive 'run-a'
        $r = Invoke-RepairRun -WorkDir $w -Names @('bogus') -Facts $script:okFacts -LastRun $script:fresh -Say { param($t) } -Ask { $true } -Prompt { '' } -RestorePointCreator { @() }
        $r.ExitCode | Should -Be 2
        (Test-Path -LiteralPath (Join-Path $w 'repair')) | Should -BeFalse
    }

    It 'refuses without a fresh backup and creates no run folder' {
        $w = Join-Path $TestDrive 'run-b'
        $r = Invoke-RepairRun -WorkDir $w -Names @('cleanup') -Facts $script:okFacts -LastRun $null -Say { param($t) } -Ask { $true } -Prompt { '' } -RestorePointCreator { @() }
        $r.ExitCode | Should -Be 2
        (Test-Path -LiteralPath (Join-Path $w 'repair')) | Should -BeFalse
    }

    It 'runs the chosen module, saves before and after audits and the report, and exits 0' {
        $w = Join-Path $TestDrive 'run-c'
        $fr = New-FakeRunner
        $ops = New-FakeOps
        $r = Invoke-RepairRun -WorkDir $w -Names @('cleanup') -Facts $script:okFacts -LastRun $script:fresh `
            -Collectors (New-RunCollectors) -Runner $fr.Runner -Ops $ops.Ops -Ask { $true } -Prompt { '' } -RestorePointCreator { @() } -Say { param($t) } `
            -Roots @{ 'temp-user' = @(); 'temp-win' = @(); 'wu-download' = @(); 'dumps' = @() }
        $r.ExitCode | Should -Be 0
        foreach ($f in 'audit-before.json', 'audit-after.json', 'raport.txt') { (Test-Path -LiteralPath (Join-Path $r.RunDir $f)) | Should -BeTrue -Because $f }
        $ops.Log | Should -Contain 'recycle'
        (Get-Content -LiteralPath (Join-Path $r.RunDir 'raport.txt') -Raw -Encoding UTF8) | Should -Match 'STAN PRZED'
    }

    It 'skips the after audit when nothing was done' {
        $w = Join-Path $TestDrive 'run-d'
        $r = Invoke-RepairRun -WorkDir $w -Names @('cleanup') -Facts $script:okFacts -LastRun $script:fresh -Collectors (New-RunCollectors) `
            -Runner (New-FakeRunner).Runner -Ops (New-FakeOps).Ops -Ask { $false } -Prompt { '' } -RestorePointCreator { @() } -Say { param($t) } `
            -Roots @{ 'temp-user' = @(); 'temp-win' = @(); 'wu-download' = @(); 'dumps' = @() }
        $r.ExitCode | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $r.RunDir 'audit-after.json')) | Should -BeFalse
    }

    It 'exits 1 when a module fails but still runs the remaining ones' {
        $w = Join-Path $TestDrive 'run-e'
        $ops = New-FakeOps -States @{ BITS = 'Running'; wuauserv = 'Running'; appidsvc = 'Running'; cryptsvc = 'Running' } -FailRename
        $sr = Join-Path $TestDrive 'sr-e'
        New-Item -ItemType Directory -Force -Path (Join-Path $sr 'SoftwareDistribution') | Out-Null
        $r = Invoke-RepairRun -WorkDir $w -Names @('windows-update', 'cleanup') -Facts $script:okFacts -LastRun $script:fresh -Collectors (New-RunCollectors) `
            -Runner (New-FakeRunner).Runner -Ops $ops.Ops -Ask { $true } -Prompt { '' } -RestorePointCreator { @() } -Say { param($t) } -SystemRoot $sr `
            -Roots @{ 'temp-user' = @(); 'temp-win' = @(); 'wu-download' = @(); 'dumps' = @() }
        $r.ExitCode | Should -Be 1
        @($r.Results).Count | Should -Be 2
        (@($r.Results) | Where-Object { $_.Name -eq 'windows-update' }).Status | Should -Be 'fail'
        (@($r.Results) | Where-Object { $_.Name -eq 'cleanup' }).Status | Should -Be 'done'
    }
}

Describe 'Invoke-RepairUndo' {
    It 'asks, re-enables the recorded startup items from the newest run and marks them undone' {
        $w = Join-Path $TestDrive 'undo-a'
        $dir = Join-Path (Join-Path $w 'repair') '20261010-100000'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-UndoRecord -Dir $dir -Record @{ module = 'startup'; kind = 'task'; name = 'Adobe'; location = '\' }
        $ops = New-FakeOps
        $r = Invoke-RepairUndo -WorkDir $w -Module 'startup' -Ops $ops.Ops -Ask { $true } -Say { param($t) }
        $r.ExitCode | Should -Be 0
        $ops.Log | Should -Contain 'enable:Adobe'
        Get-LatestUndoDir -WorkDir $w -Module 'startup' | Should -BeNullOrEmpty
    }
    It 'does nothing when the answer is no' {
        $w = Join-Path $TestDrive 'undo-b'
        $dir = Join-Path (Join-Path $w 'repair') '20261010-100000'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-UndoRecord -Dir $dir -Record @{ module = 'startup'; kind = 'task'; name = 'Adobe'; location = '\' }
        $ops = New-FakeOps
        $r = Invoke-RepairUndo -WorkDir $w -Module 'startup' -Ops $ops.Ops -Ask { $false } -Say { param($t) }
        $r.ExitCode | Should -Be 3
        $ops.Log.Count | Should -Be 0
    }
    It 'says there is nothing to undo, and refuses modules that cannot be undone' {
        $w = Join-Path $TestDrive 'undo-c'
        (Invoke-RepairUndo -WorkDir $w -Module 'startup' -Ask { $true } -Say { param($t) }).ExitCode | Should -Be 0
        (Invoke-RepairUndo -WorkDir $w -Module 'cleanup' -Ask { $true } -Say { param($t) }).ExitCode | Should -Be 2
        (Invoke-RepairUndo -WorkDir $w -Module 'bogus' -Ask { $true } -Say { param($t) }).ExitCode | Should -Be 2
    }
}

Describe 'repair entry script' {
    BeforeAll {
        $script:rootDir = Split-Path $PSScriptRoot -Parent
        $script:pwshExe = (Get-Process -Id $PID).Path
        function Invoke-Entry([string[]]$ArgList) {
            Push-Location $script:rootDir
            try { & $script:pwshExe -NoProfile -File @ArgList *> $null; return $LASTEXITCODE } finally { Pop-Location }
        }
    }
    It 'refuses -Yes with exit code 2' {
        Invoke-Entry @((Join-Path $script:rootDir 'Repair-Windows.ps1'), '-Yes') | Should -Be 2
    }
    It 'rejects an unknown module and a malformed image date with exit code 2' {
        Invoke-Entry @((Join-Path $script:rootDir 'Repair-Windows.ps1'), '-Modules', 'bogus') | Should -Be 2
        Invoke-Entry @((Join-Path $script:rootDir 'Repair-Windows.ps1'), '-ImageDate', '2026-13-45') | Should -Be 2
    }
    It 'is reachable through Invoke-Resurect.ps1 -Action repair and keeps the same refusals' {
        Invoke-Entry @((Join-Path $script:rootDir 'Invoke-Resurect.ps1'), '-Action', 'repair', '-Yes') | Should -Be 2
        Invoke-Entry @((Join-Path $script:rootDir 'Invoke-Resurect.ps1'), '-Action', 'repair', '-Modules', 'bogus') | Should -Be 2
    }
}
