BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $src = Join-Path $script:root 'src'
    Import-Module (Join-Path $src 'WinResurect.psm1') -Force
    Import-Module (Join-Path $src 'DailyBackup.psm1') -Force

    function New-RawConfig {
        param([hashtable]$Override = @{})
        $c = [ordered]@{
            target    = [ordered]@{ type = 'usb'; label = 'BACKUP' }
            folders   = @('C:\Users\Jan\Documents')
            excludes  = @('*.tmp')
            schedule  = [ordered]@{ time = '12:30' }
            retention = [ordered]@{ daily = 14; weekly = 8; monthly = 6 }
        }
        foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }
        return ($c | ConvertTo-Json -Depth 6)
    }
    function Write-TestJson([string]$Name, [string]$Json) {
        $p = Join-Path $TestDrive $Name
        Set-Content -LiteralPath $p -Value $Json -Encoding UTF8
        return $p
    }
    function New-TestDailyConfig {
        param(
            [hashtable]$Target = @{ Type = 'usb'; Label = 'BACKUP'; Share = ''; User = ''; Folder = 'WinResurectDaily' },
            [string[]]$Folders = @('C:\Users\Jan\Documents'),
            [string[]]$Excludes = @('*.tmp')
        )
        [pscustomobject]@{
            Target = [pscustomobject]$Target; Folders = $Folders; Excludes = $Excludes; Time = '12:30'
            Retention = [pscustomobject]@{ Daily = 14; Weekly = 8; Monthly = 6 }; ReportEnabled = $false
        }
    }
}

Describe 'Read-DailyConfig' {
    It 'reads a USB config and fills defaults' {
        $c = Read-DailyConfig -Path (Write-TestJson 'ok.json' (New-RawConfig))
        $c.Target.Type | Should -Be 'usb'
        $c.Target.Label | Should -Be 'BACKUP'
        $c.Target.Folder | Should -Be 'WinResurectDaily'
        $c.Folders.Count | Should -Be 1
        $c.Time | Should -Be '12:30'
        $c.Retention.Daily | Should -Be 14
        $c.Retention.Weekly | Should -Be 8
        $c.Retention.Monthly | Should -Be 6
        $c.ReportEnabled | Should -BeFalse
    }

    It 'fills time and retention defaults when the sections are missing' {
        $json = '{ "target": { "type": "usb", "label": "BACKUP" }, "folders": ["C:\\Dane"] }'
        $c = Read-DailyConfig -Path (Write-TestJson 'min.json' $json)
        $c.Time | Should -Be '12:30'
        $c.Retention.Monthly | Should -Be 6
        @($c.Excludes).Count | Should -Be 0
    }

    It 'reads an SMB target and trims the trailing backslash' {
        $t = [ordered]@{ type = 'smb'; share = '\\nas\share\'; user = 'uzytkownik'; folder = 'Kopie' }
        $c = Read-DailyConfig -Path (Write-TestJson 'smb.json' (New-RawConfig @{ target = $t }))
        $c.Target.Type | Should -Be 'smb'
        $c.Target.Share | Should -Be '\\nas\share'
        $c.Target.User | Should -Be 'uzytkownik'
        $c.Target.Folder | Should -Be 'Kopie'
    }

    It 'trims folders and removes case-insensitive duplicates' {
        $f = @('C:\Users\Jan\Documents', ' c:\users\jan\documents ', 'D:\Ksiegowosc')
        $c = Read-DailyConfig -Path (Write-TestJson 'dup.json' (New-RawConfig @{ folders = $f }))
        @($c.Folders).Count | Should -Be 2
    }

    It 'rejects a missing file and invalid json' {
        { Read-DailyConfig -Path (Join-Path $TestDrive 'nie-ma.json') } | Should -Throw '*Brak pliku*'
        { Read-DailyConfig -Path (Write-TestJson 'bad.json' '{ nie json') } | Should -Throw '*JSON*'
    }

    It 'rejects every invalid configuration and names the problem' {
        $cases = @(
            @{ Json = (New-RawConfig @{ target = [ordered]@{ type = 'dvd' } }); Match = '*type*' },
            @{ Json = (New-RawConfig @{ target = [ordered]@{ type = 'usb'; label = '' } }); Match = '*etykiet*' },
            @{ Json = (New-RawConfig @{ target = [ordered]@{ type = 'usb'; label = 'a/b' } }); Match = '*etykiet*' },
            @{ Json = (New-RawConfig @{ target = [ordered]@{ type = 'smb'; share = 'nas/share'; user = 'u' } }); Match = '*share*' },
            @{ Json = (New-RawConfig @{ target = [ordered]@{ type = 'smb'; share = '\\nas\share'; user = '' } }); Match = '*user*' },
            @{ Json = (New-RawConfig @{ target = [ordered]@{ type = 'usb'; label = 'B'; folder = '..' } }); Match = '*folder*' },
            @{ Json = (New-RawConfig @{ folders = @() }); Match = '*folders*' },
            @{ Json = (New-RawConfig @{ folders = @('Dokumenty\Jan') }); Match = '*bezwzgl*' },
            @{ Json = (New-RawConfig @{ schedule = [ordered]@{ time = '25:00' } }); Match = '*time*' },
            @{ Json = (New-RawConfig @{ retention = [ordered]@{ daily = 0; weekly = 8; monthly = 6 } }); Match = '*retention*' },
            @{ Json = (New-RawConfig @{ retention = [ordered]@{ daily = 'abc'; weekly = 8; monthly = 6 } }); Match = '*retention*' }
        )
        $i = 0
        foreach ($case in $cases) {
            $i++
            $p = Write-TestJson "case$i.json" $case.Json
            { Read-DailyConfig -Path $p } | Should -Throw $case.Match
        }
    }
}

Describe 'Test-DailyTargetParams' {
    It 'accepts USB with a label and SMB with share and user, and applies the default folder' {
        $u = Test-DailyTargetParams -Target usb -Label 'BACKUP'
        $u.Type | Should -Be 'usb'
        $u.Folder | Should -Be 'WinResurectDaily'
        $s = Test-DailyTargetParams -Target smb -Share '\\nas\share\' -User 'uzytkownik'
        $s.Share | Should -Be '\\nas\share'
    }

    It 'rejects bad parameters' {
        { Test-DailyTargetParams -Target usb -Label 'zły/label' } | Should -Throw
        { Test-DailyTargetParams -Target usb } | Should -Throw
        { Test-DailyTargetParams -Target smb -Share 'x' -User 'u' } | Should -Throw
        { Test-DailyTargetParams -Target smb -Share '\\nas\share' } | Should -Throw
        { Test-DailyTargetParams -Target dvd } | Should -Throw
    }
}

Describe 'Resolve-DailyTarget' {
    BeforeAll {
        $script:vols = @(
            [pscustomobject]@{ Drive = 'C:'; Label = 'System'; FileSystem = 'NTFS'; DriveType = 3 },
            [pscustomobject]@{ Drive = 'E:'; Label = 'BACKUP'; FileSystem = 'NTFS'; DriveType = 3 },
            [pscustomobject]@{ Drive = 'F:'; Label = 'INNY'; FileSystem = 'NTFS'; DriveType = 2 }
        )
    }

    It 'finds the USB disk by label (case-insensitive) and builds the repository path' {
        $t = Resolve-DailyTarget -Config (New-TestDailyConfig) -Volumes $script:vols -ComputerName 'PC1'
        $t.Ok | Should -BeTrue
        $t.Drive | Should -Be 'E:'
        $t.Repository | Should -Be 'E:\WinResurectDaily\PC1'
        $c = New-TestDailyConfig -Target @{ Type = 'usb'; Label = 'backup'; Share = ''; User = ''; Folder = 'WinResurectDaily' }
        (Resolve-DailyTarget -Config $c -Volumes $script:vols -ComputerName 'PC1').Repository | Should -Be 'E:\WinResurectDaily\PC1'
    }

    It 'reports an unavailable target when the label is missing' {
        $c = New-TestDailyConfig -Target @{ Type = 'usb'; Label = 'NIEMA'; Share = ''; User = ''; Folder = 'WinResurectDaily' }
        $t = Resolve-DailyTarget -Config $c -Volumes $script:vols -ComputerName 'PC1'
        $t.Ok | Should -BeFalse
        $t.Reason | Should -Match 'niedostępny'
    }

    It 'refuses an ambiguous label' {
        $two = @($script:vols) + @([pscustomobject]@{ Drive = 'G:'; Label = 'BACKUP'; FileSystem = 'NTFS'; DriveType = 3 })
        $t = Resolve-DailyTarget -Config (New-TestDailyConfig) -Volumes $two -ComputerName 'PC1'
        $t.Ok | Should -BeFalse
        $t.Reason | Should -Match 'więcej niż jeden'
    }

    It 'handles an empty volume list' {
        (Resolve-DailyTarget -Config (New-TestDailyConfig) -Volumes @() -ComputerName 'PC1').Ok | Should -BeFalse
    }

    It 'builds an SMB repository under the share and reports the share root' {
        $c = New-TestDailyConfig -Target @{ Type = 'smb'; Label = ''; Share = '\\nas\share\sub'; User = 'u'; Folder = 'WinResurectDaily' }
        $t = Resolve-DailyTarget -Config $c -Volumes @() -ComputerName 'PC1'
        $t.Ok | Should -BeTrue
        $t.Repository | Should -Be '\\nas\share\sub\WinResurectDaily\PC1'
        $t.ShareRoot | Should -Be '\\nas\share'
    }
}

Describe 'restic arguments' {
    It 'builds the backup command with VSS, host, excludes and folders' {
        $a = @(Get-DailyBackupArgs -Config (New-TestDailyConfig) -Folders @('C:\A', 'D:\B') -ComputerName 'PC1')
        $a[0] | Should -Be 'backup'
        $a | Should -Contain '--use-fs-snapshot'
        $a | Should -Contain '--json'
        $a[($a.IndexOf('--host') + 1)] | Should -Be 'PC1'
        $a[($a.IndexOf('--exclude') + 1)] | Should -Be '*.tmp'
        $a[-2] | Should -Be 'C:\A'
        $a[-1] | Should -Be 'D:\B'
        $a | Should -Not -Contain '--limit-upload'
    }

    It 'builds forget with retention, check with a subset and the init probe' {
        $f = @(Get-DailyForgetArgs -Config (New-TestDailyConfig) -ComputerName 'PC1')
        $f[0] | Should -Be 'forget'
        $f[($f.IndexOf('--keep-daily') + 1)] | Should -Be '14'
        $f[($f.IndexOf('--keep-weekly') + 1)] | Should -Be '8'
        $f[($f.IndexOf('--keep-monthly') + 1)] | Should -Be '6'
        $f | Should -Contain '--prune'
        @(Get-DailyCheckArgs) | Should -Be @('check', '--read-data-subset=5%')
        @(Get-DailyInitCheckArgs) | Should -Be @('cat', 'config')
    }
}

Describe 'status and summaries' {
    It 'maps restic exit codes' {
        ConvertTo-DailyStatus -ExitCode 0 | Should -Be 'ok'
        ConvertTo-DailyStatus -ExitCode 3 | Should -Be 'warn'
        ConvertTo-DailyStatus -ExitCode 1 | Should -Be 'fail'
        ConvertTo-DailyStatus -ExitCode 12 | Should -Be 'fail'
        ConvertTo-DailyStatus -ExitCode -1 | Should -Be 'fail'
        Get-WorseStatus -A 'ok' -B 'warn' | Should -Be 'warn'
        Get-WorseStatus -A 'fail' -B 'warn' | Should -Be 'fail'
    }

    It 'reads added bytes and a short snapshot id from the json summary' {
        $s = ConvertFrom-ResticSummary -Lines @('niejson', '{"message_type":"status"}', '{"message_type":"summary","data_added":4096,"snapshot_id":"0123456789abcdef"}')
        $s.AddedBytes | Should -Be 4096
        $s.Snapshot | Should -Be '01234567'
        (ConvertFrom-ResticSummary -Lines @('x')).AddedBytes | Should -Be 0
    }

    It 'parses snapshots including nanosecond timestamps' {
        $json = '[{"id":"aaaaaaaaaaaaaaaa","short_id":"aaaaaaaa","time":"2026-10-14T12:30:05.123456789+02:00","hostname":"PC1","paths":["C:\\Users\\Jan\\Documents"]},{"id":"bbbbbbbbbbbbbbbb","short_id":"bbbbbbbb","time":"2026-10-15T12:30:01+02:00","hostname":"PC1","paths":["D:\\B"]}]'
        $s = @(ConvertFrom-ResticSnapshots -Json $json)
        $s.Count | Should -Be 2
        $s[0].ShortId | Should -Be 'aaaaaaaa'
        $s[0].Time.Year | Should -Be 2026
        $s[1].Host | Should -Be 'PC1'
        @(ConvertFrom-ResticSnapshots -Json '').Count | Should -Be 0
        @(ConvertFrom-ResticSnapshots -Json 'nie json').Count | Should -Be 0
    }

    It 'strips paths and control characters from notes and builds failure notes' {
        $n = Format-Note -Text ("Błąd: C:\Users\Jan\umowa.docx: odmowa oraz \\nas\share\x" + [char]7)
        $n | Should -Not -Match 'Jan'
        $n | Should -Not -Match 'nas'
        $n | Should -Match '<path>'
        (Format-Note -Text ('a' * 500)).Length | Should -Be 200
        $lines = @('a', 'b', '{"message_type":"error","error":{"message":"repository is already locked"}}', 'd')
        $f = Get-FailureNote -Lines $lines
        $f | Should -Match 'repository is already locked'
        $f | Should -Not -Match '(^|\| )a( \||$)'
    }

    It 'splits folders into existing and missing using the injected check' {
        $exists = { param($p) $p -eq 'C:\A' }
        $r = Select-ExistingFolders -Folders @('C:\A', 'D:\B') -Exists $exists
        @($r.Existing) | Should -Be @('C:\A')
        @($r.Missing) | Should -Be @('D:\B')
        @((Select-ExistingFolders -Folders @() -Exists $exists).Existing).Count | Should -Be 0
    }
}

Describe 'last run and status text' {
    BeforeAll {
        $script:t0 = [datetime]::SpecifyKind([datetime]'2026-10-14T10:30:00', 'Utc')
        $script:t1 = $script:t0.AddMinutes(5)
    }

    It 'keeps last_success from the previous run when the new run fails' {
        $ok = New-LastRun -Status ok -Started $script:t0 -Finished $script:t1 -AddedBytes 100 -Snapshot 'abc' -Snapshots 3
        $ok.last_success | Should -Be '2026-10-14T10:35:00Z'
        $bad = New-LastRun -Status fail -Started $script:t1 -Finished $script:t1.AddMinutes(1) -Note 'cel niedostępny' -Previous ([pscustomobject]$ok)
        $bad.status | Should -Be 'fail'
        $bad.last_success | Should -Be '2026-10-14T10:35:00Z'
        (New-LastRun -Status fail -Started $script:t0 -Finished $script:t1).last_success | Should -Be ''
    }

    It 'saves and reads the last run and tolerates a missing or corrupt file' {
        $p = Join-Path $TestDrive 'last-run.json'
        Read-LastRun -Path $p | Should -BeNullOrEmpty
        Save-LastRun -Path $p -LastRun (New-LastRun -Status warn -Started $script:t0 -Finished $script:t1 -Skipped @('D:\B') -Note 'pominięto 1')
        $r = Read-LastRun -Path $p
        $r.status | Should -Be 'warn'
        @($r.skipped_folders) | Should -Be @('D:\B')
        Set-Content -LiteralPath $p -Value '{ uszkodzony' -Encoding UTF8
        Read-LastRun -Path $p | Should -BeNullOrEmpty
    }

    It 'judges staleness by last_success with a 48 hour limit' {
        $now = $script:t1
        $fresh = [pscustomobject](New-LastRun -Status ok -Started $script:t0.AddHours(-40) -Finished $script:t0.AddHours(-40))
        Get-DailyStaleness -LastRun $fresh -Now $now | Should -Be 'fresh'
        $old = [pscustomobject](New-LastRun -Status ok -Started $script:t0.AddHours(-60) -Finished $script:t0.AddHours(-60))
        Get-DailyStaleness -LastRun $old -Now $now | Should -Be 'stale'
        $never = [pscustomobject](New-LastRun -Status fail -Started $script:t0 -Finished $script:t1)
        Get-DailyStaleness -LastRun $never -Now $now | Should -Be 'never'
        Get-DailyStaleness -LastRun $null -Now $now | Should -Be 'never'
    }

    It 'prints a status text that flags stale copies' {
        $old = [pscustomobject](New-LastRun -Status ok -Started $script:t0.AddHours(-60) -Finished $script:t0.AddHours(-60) -AddedBytes 2048 -Snapshots 4)
        $txt = Get-DailyStatusText -LastRun $old -Now $script:t1
        $txt | Should -Match 'NIEAKTUALNA'
        $txt | Should -Match '4'
        $okTxt = Get-DailyStatusText -LastRun ([pscustomobject](New-LastRun -Status ok -Started $script:t0 -Finished $script:t1)) -Now $script:t1
        $okTxt | Should -Not -Match 'NIEAKTUALNA'
        (Get-DailyStatusText -LastRun $null -Now $script:t1) | Should -Match 'brak'
    }
}

Describe 'Write-DailyLog' {
    It 'appends lines and rotates the log keeping a fixed number of files' {
        $p = Join-Path $TestDrive 'daily.log'
        Write-DailyLog -Path $p -Lines @('pierwszy')
        (Get-Content -LiteralPath $p -Raw) | Should -Match 'pierwszy'
        foreach ($i in 1..8) {
            Write-DailyLog -Path $p -Lines @("linia $i " + ('x' * 30)) -MaxBytes 20 -Keep 3
        }
        Test-Path "$p.1" | Should -BeTrue
        Test-Path "$p.2" | Should -BeTrue
        Test-Path "$p.3" | Should -BeFalse
        (Get-Content -LiteralPath $p -Raw) | Should -Match 'linia 8'
    }
}

Describe 'Invoke-DailyJob (backup)' {
    BeforeAll {
        function New-TestCredential([string]$User, [string]$Pass) {
            New-Object System.Management.Automation.PSCredential($User, (ConvertTo-SecureString $Pass -AsPlainText -Force))
        }
        $script:usbVol = @([pscustomobject]@{ Drive = 'E:'; Label = 'BACKUP'; FileSystem = 'NTFS'; DriveType = 3 })
        $script:smbTarget = @{ Type = 'smb'; Label = ''; Share = '\\nas\share'; User = 'uzytkownik'; Folder = 'WinResurectDaily' }
        function Invoke-TestJob {
            param($Config, [object[]]$Volumes = $script:usbVol, [string[]]$Existing = @('C:\Users\Jan\Documents'), $Credential = $null, [scriptblock]$Reader = $null)
            $script:existing = $Existing
            $exists = { param($p) $script:existing -contains $p }
            $cred = $Credential
            $reader = { $cred }.GetNewClosure()
            if ($Reader) { $reader = $Reader }
            Invoke-DailyJob -Mode backup -Config $Config -Volumes $Volumes -Runner $script:runner -WorkDir $script:work `
                -ReadSmbCredential $reader -Connector $script:connector -Disconnector $script:disconnector `
                -PathExists $exists -Clock { [datetime]::SpecifyKind([datetime]'2026-10-14T10:30:00', 'Utc') } `
                -ComputerName 'PC1' -ResticVersion '0.18.0'
        }
    }
    BeforeEach {
        $script:work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work | Out-Null
        $script:calls = New-Object System.Collections.ArrayList
        $script:envSeen = $null
        $script:backupExit = 0
        $script:backupOut = @('{"message_type":"summary","data_added":2048,"snapshot_id":"deadbeefcafe"}')
        $script:netFail = $false
        $script:seenPassword = $null
        $script:runner = {
            param($Exe, $ArgList)
            $script:calls.Add("$Exe " + ($ArgList -join ' ')) | Out-Null
            if ($ArgList[0] -eq 'backup') {
                $script:envSeen = @{ Repo = $env:RESTIC_REPOSITORY; Pass = $env:RESTIC_PASSWORD_FILE }
                if ($script:backupExit -eq -99) { throw 'restic.exe nie istnieje' }
                return @{ ExitCode = $script:backupExit; Output = $script:backupOut }
            }
            if ($ArgList[0] -eq 'snapshots') { return @{ ExitCode = 0; Output = @('[{"id":"a","short_id":"a","time":"2026-10-14T12:00:00+02:00","hostname":"PC1","paths":[]},{"id":"b","short_id":"b","time":"2026-10-15T12:00:00+02:00","hostname":"PC1","paths":[]}]') } }
            return @{ ExitCode = 0; Output = @() }
        }
        $script:connector = {
            param($Share, $User, $Password)
            $script:calls.Add("connect $Share $User") | Out-Null
            $script:seenPassword = $Password
            if ($script:netFail) { return @{ ExitCode = 1219; Output = @('istnieje już połączenie') } }
            return @{ ExitCode = 0; Output = @() }
        }
        $script:disconnector = { param($Share) $script:calls.Add("disconnect $Share") | Out-Null; return @{ ExitCode = 0; Output = @() } }
    }

    It 'backs up to the USB disk found by label with the right repository and password file' {
        $before = $env:RESTIC_REPOSITORY
        $r = Invoke-TestJob (New-TestDailyConfig)
        $r.ExitCode | Should -Be 0
        $r.Status | Should -Be 'ok'
        @($script:calls) | Should -Be @(
            'restic unlock',
            'restic backup --json --use-fs-snapshot --host PC1 --exclude *.tmp C:\Users\Jan\Documents',
            'restic snapshots --json --host PC1')
        $script:envSeen.Repo | Should -Be 'E:\WinResurectDaily\PC1'
        $script:envSeen.Pass | Should -Be (Join-Path $script:work 'repo.pass')
        $env:RESTIC_REPOSITORY | Should -Be $before
        $lr = Read-LastRun -Path (Join-Path $script:work 'last-run.json')
        $lr.status | Should -Be 'ok'
        $lr.added_bytes | Should -Be 2048
        $lr.snapshot | Should -Be 'deadbeef'
        $lr.snapshots | Should -Be 2
        $lr.restic_version | Should -Be '0.18.0'
        $lr.last_success | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $script:work 'daily.log') -Raw) | Should -Match 'ok'
    }

    It 'skips folders that do not exist, backs up the rest and ends with warn' {
        $c = New-TestDailyConfig -Folders @('C:\Users\Jan\Documents', 'D:\Zniknal')
        $r = Invoke-TestJob $c
        $r.ExitCode | Should -Be 0
        $r.Status | Should -Be 'warn'
        ($script:calls | Where-Object { $_ -like 'restic backup*' }) | Should -Not -Match 'Zniknal'
        @((Read-LastRun -Path (Join-Path $script:work 'last-run.json')).skipped_folders) | Should -Be @('D:\Zniknal')
    }

    It 'fails without running restic when no listed folder exists' {
        $r = Invoke-TestJob (New-TestDailyConfig) -Existing @()
        $r.ExitCode | Should -Be 1
        $r.Status | Should -Be 'fail'
        ($script:calls | Where-Object { $_ -like 'restic backup*' }) | Should -BeNullOrEmpty
    }

    It 'fails with an unavailable-target note and never touches restic when the USB label is missing' {
        $c = New-TestDailyConfig -Target @{ Type = 'usb'; Label = 'NIEMA'; Share = ''; User = ''; Folder = 'WinResurectDaily' }
        $r = Invoke-TestJob $c
        $r.ExitCode | Should -Be 1
        $script:calls.Count | Should -Be 0
        (Read-LastRun -Path (Join-Path $script:work 'last-run.json')).note | Should -Match 'niedostępny'
    }

    It 'maps restic exit code 3 to warn and others to fail with a note without client paths' {
        $script:backupExit = 3
        (Invoke-TestJob (New-TestDailyConfig)).Status | Should -Be 'warn'
        $script:backupExit = 1
        $script:backupOut = @('Fatal: unable to open repository at E:\WinResurectDaily\PC1')
        $r = Invoke-TestJob (New-TestDailyConfig)
        $r.ExitCode | Should -Be 1
        $r.LastRun.note | Should -Match 'unable to open repository'
        $r.LastRun.note | Should -Not -Match 'WinResurectDaily'
    }

    It 'keeps last_success from an earlier good run when the next one fails' {
        Invoke-TestJob (New-TestDailyConfig) | Out-Null
        $good = (Read-LastRun -Path (Join-Path $script:work 'last-run.json')).last_success
        $script:backupExit = 1
        Invoke-TestJob (New-TestDailyConfig) | Out-Null
        $lr = Read-LastRun -Path (Join-Path $script:work 'last-run.json')
        $lr.status | Should -Be 'fail'
        $lr.last_success | Should -Be $good
    }

    It 'turns a runner exception into a failed run instead of throwing' {
        $script:backupExit = -99
        $r = Invoke-TestJob (New-TestDailyConfig)
        $r.ExitCode | Should -Be 1
        $r.LastRun.note | Should -Match 'nie istnieje'
    }

    It 'connects to SMB through the connector, never leaks the password, and always disconnects' {
        $c = New-TestDailyConfig -Target $script:smbTarget
        $r = Invoke-TestJob $c -Volumes @() -Credential (New-TestCredential 'uzytkownik' 'Sekret1')
        $r.ExitCode | Should -Be 0
        $script:calls[0] | Should -Be 'connect \\nas\share uzytkownik'
        $script:calls[-1] | Should -Be 'disconnect \\nas\share'
        $script:seenPassword | Should -Be 'Sekret1'
        $script:envSeen.Repo | Should -Be '\\nas\share\WinResurectDaily\PC1'
        (@($script:calls) -join "`n") | Should -Not -Match 'Sekret1'
        $all = (Get-ChildItem $script:work -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $all | Should -Not -Match 'Sekret1'
    }

    It 'fails without connecting when SMB credentials are missing' {
        $c = New-TestDailyConfig -Target $script:smbTarget
        $r = Invoke-TestJob $c -Volumes @() -Credential $null
        $r.ExitCode | Should -Be 1
        $r.LastRun.note | Should -Match 'poświadczeń'
        $script:calls.Count | Should -Be 0
    }

    It 'fails with the Windows error code when the share cannot be connected and runs no restic command' {
        $script:netFail = $true
        $c = New-TestDailyConfig -Target $script:smbTarget
        $r = Invoke-TestJob $c -Volumes @() -Credential (New-TestCredential 'uzytkownik' 'Sekret1')
        $r.ExitCode | Should -Be 1
        $r.LastRun.note | Should -Match '1219'
        $r.LastRun.note | Should -Not -Match 'Sekret1'
        ($script:calls | Where-Object { $_ -like 'restic*' }) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DailyJob (maintenance and init)' {
    BeforeAll {
        $script:usbVol2 = @([pscustomobject]@{ Drive = 'E:'; Label = 'BACKUP'; FileSystem = 'NTFS'; DriveType = 3 })
        function Invoke-TestMode {
            param([string]$Mode)
            Invoke-DailyJob -Mode $Mode -Config (New-TestDailyConfig) -Volumes $script:usbVol2 -Runner $script:runner2 -WorkDir $script:work2 `
                -Clock { [datetime]::SpecifyKind([datetime]'2026-10-14T10:30:00', 'Utc') } -ComputerName 'PC1'
        }
    }
    BeforeEach {
        $script:work2 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work2 | Out-Null
        $script:calls2 = New-Object System.Collections.ArrayList
        $script:catExit = 0; $script:checkExit = 0; $script:forgetExit = 0; $script:initExit = 0
        $script:runner2 = {
            param($Exe, $ArgList)
            $script:calls2.Add("$Exe " + ($ArgList -join ' ')) | Out-Null
            switch ($ArgList[0]) {
                'cat' { return @{ ExitCode = $script:catExit; Output = @() } }
                'init' { return @{ ExitCode = $script:initExit; Output = @() } }
                'forget' { return @{ ExitCode = $script:forgetExit; Output = @() } }
                'check' { return @{ ExitCode = $script:checkExit; Output = @('Fatal: pack abc: ID not found') } }
                default { return @{ ExitCode = 0; Output = @() } }
            }
        }
    }

    It 'runs forget then check and writes last-maintenance.json' {
        $r = Invoke-TestMode 'maintenance'
        $r.ExitCode | Should -Be 0
        @($script:calls2) | Should -Be @(
            'restic forget --host PC1 --keep-daily 14 --keep-weekly 8 --keep-monthly 6 --prune',
            'restic check --read-data-subset=5%')
        (Read-LastRun -Path (Join-Path $script:work2 'last-maintenance.json')).status | Should -Be 'ok'
        Test-Path (Join-Path $script:work2 'last-run.json') | Should -BeFalse
    }

    It 'takes the worst status of forget and check and notes the failing step' {
        $script:checkExit = 1
        $r = Invoke-TestMode 'maintenance'
        $r.ExitCode | Should -Be 1
        $r.LastRun.note | Should -Match 'ID not found'
    }

    It 'does not run init when the repository already exists' {
        $r = Invoke-TestMode 'init'
        $r.ExitCode | Should -Be 0
        @($script:calls2) | Should -Be @('restic cat config')
    }

    It 'initializes a missing repository and fails when init fails' {
        $script:catExit = 10
        $r = Invoke-TestMode 'init'
        $r.ExitCode | Should -Be 0
        @($script:calls2) | Should -Be @('restic cat config', 'restic init')
        $script:initExit = 1
        $script:calls2.Clear()
        (Invoke-TestMode 'init').ExitCode | Should -Be 1
    }
}

Describe 'Get-DailyTaskSpecs' {
    BeforeAll { $script:specs = @(Get-DailyTaskSpecs -InstallDir 'C:\ProgramData\WinResurect' -Time '12:30') }

    It 'defines the daily backup and the weekly maintenance task' {
        $script:specs.Count | Should -Be 2
        @($script:specs | ForEach-Object { $_.Name }) | Should -Be @('WinResurect-Daily', 'WinResurect-Maintenance')
    }

    It 'runs scripts as files with a bypassed execution policy from the install folder' {
        $d = $script:specs[0]
        $d.Execute | Should -Be 'powershell.exe'
        $d.Arguments | Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\WinResurect\Run-DailyBackup.ps1" -Mode backup'
        $script:specs[1].Arguments | Should -Match '-Mode maintenance'
    }

    It 'sets triggers and reliability options per the spec' {
        $d = $script:specs[0]
        $d.TriggerType | Should -Be 'Daily'
        $d.At | Should -Be '12:30'
        $d.StartWhenAvailable | Should -BeTrue
        $d.AllowStartIfOnBatteries | Should -BeFalse
        $d.RestartCount | Should -Be 2
        $d.RestartIntervalMinutes | Should -Be 30
        $d.ExecutionTimeLimitHours | Should -Be 6
        $d.MultipleInstances | Should -Be 'IgnoreNew'
        $m = $script:specs[1]
        $m.TriggerType | Should -Be 'Weekly'
        $m.DaysOfWeek | Should -Be 'Sunday'
        $m.At | Should -Be '20:00'
        $m.RestartCount | Should -Be 0
    }
}

Describe 'restore helpers' {
    It 'builds the restore command with optional include paths' {
        @(Get-RestoreArgs -SnapshotId 'aaaaaaaa' -Target 'C:\Odzysk') | Should -Be @('restore', 'aaaaaaaa', '--target', 'C:\Odzysk')
        $a = @(Get-RestoreArgs -SnapshotId 'aaaaaaaa' -Target 'C:\Odzysk' -Include @('C:\Dane\A', 'C:\Dane\B'))
        $a | Should -Be @('restore', 'aaaaaaaa', '--target', 'C:\Odzysk', '--include', 'C:\Dane\A', '--include', 'C:\Dane\B')
    }

    It 'never accepts a restore target that overwrites, lies in or contains a backed-up folder' {
        $folders = @('C:\Users\Jan\Documents', 'D:\Ksiegowosc')
        Test-RestoreTargetSafe -Target 'C:\Users\Jan\Desktop\Przywrocone_1' -Folders $folders | Should -BeTrue
        Test-RestoreTargetSafe -Target 'C:\Users\Jan\Documents' -Folders $folders | Should -BeFalse
        Test-RestoreTargetSafe -Target 'c:\users\jan\documents\\' -Folders $folders | Should -BeFalse
        Test-RestoreTargetSafe -Target 'C:\Users\Jan\Documents\Przywrocone' -Folders $folders | Should -BeFalse
        Test-RestoreTargetSafe -Target 'C:\Users\Jan' -Folders $folders | Should -BeFalse
        Test-RestoreTargetSafe -Target 'D:\' -Folders $folders | Should -BeFalse
        Test-RestoreTargetSafe -Target '' -Folders $folders | Should -BeFalse
    }

    It 'names the restore folder by date and time under the given base' {
        New-RestoreTarget -Base 'C:\Users\Jan\Desktop' -Now ([datetime]'2026-10-14T13:05:00') | Should -Be 'C:\Users\Jan\Desktop\Przywrocone_2026-10-14_1305'
    }

    It 'resolves the install home from WINRES_HOME or ProgramData' {
        $old = $env:WINRES_HOME
        try {
            $env:WINRES_HOME = 'X:\Test\Home'
            Get-DailyHome | Should -Be 'X:\Test\Home'
            Remove-Item Env:WINRES_HOME
            Get-DailyHome | Should -Match 'WinResurect$'
        }
        finally { if ($null -ne $old) { $env:WINRES_HOME = $old } else { Remove-Item Env:WINRES_HOME -ErrorAction SilentlyContinue } }
    }
}

Describe 'installer helpers' {
    It 'validates the pinned restic specification' {
        $url = 'https://github.com/restic/restic/releases/download/v0.18.0/restic_0.18.0_windows_amd64.zip'
        $sha = 'a' * 64
        $p = Join-Path $TestDrive 'restic-version.json'
        Set-Content -LiteralPath $p -Value ('{ "version": "0.18.0", "url": "' + $url + '", "sha256": "' + $sha + '" }') -Encoding UTF8
        $s = Get-ResticVersionSpec -Path $p
        $s.Version | Should -Be '0.18.0'
        $s.Sha256 | Should -Be $sha
        $badCases = @(
            ('{ "version": "0.18.0", "url": "https://evil.example/x.zip", "sha256": "' + $sha + '" }'),
            ('{ "version": "0.18.0", "url": "' + $url + '", "sha256": "zzz" }'),
            ('{ "url": "' + $url + '", "sha256": "' + $sha + '" }'),
            '{ nie json'
        )
        foreach ($bad in $badCases) {
            Set-Content -LiteralPath $p -Value $bad -Encoding UTF8
            { Get-ResticVersionSpec -Path $p } | Should -Throw
        }
        { Get-ResticVersionSpec -Path (Join-Path $TestDrive 'brak.json') } | Should -Throw
    }

    It 'compares SHA256 case-insensitively and rejects a mismatch' {
        $p = Join-Path $TestDrive 'plik.bin'
        [System.IO.File]::WriteAllBytes($p, [byte[]](1, 2, 3))
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
        Test-FileSha256 -Path $p -Expected $h.ToLower() | Should -BeTrue
        Test-FileSha256 -Path $p -Expected ('0' * 64) | Should -BeFalse
        Test-FileSha256 -Path (Join-Path $TestDrive 'brak.bin') -Expected $h | Should -BeFalse
    }

    It 'generates unambiguous random passwords' {
        $p = New-RandomPassword -Length 40
        $p.Length | Should -Be 40
        $p | Should -Match '^[abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789]+$'
        (New-RandomPassword) | Should -Not -Be (New-RandomPassword)
    }

    It 'creates a valid config for a USB and an SMB target' {
        $u = New-DailyConfigJson -Type usb -Label 'BACKUP' -Folder 'WinResurectDaily' -Time '12:30' -Folders @('C:\Users\Jan\Documents')
        $p = Join-Path $TestDrive 'u.json'
        Set-Content -LiteralPath $p -Value $u -Encoding UTF8
        (Read-DailyConfig -Path $p).Target.Label | Should -Be 'BACKUP'
        $s = New-DailyConfigJson -Type smb -Share '\\nas\share' -User 'uzytkownik' -Folder 'WinResurectDaily' -Time '13:00' -Folders @('D:\Ksiegowosc')
        Set-Content -LiteralPath $p -Value $s -Encoding UTF8
        $c = Read-DailyConfig -Path $p
        $c.Target.Share | Should -Be '\\nas\share'
        $c.Time | Should -Be '13:00'
    }

    It 'updates only the target and time of an existing config and keeps folders, excludes and retention' {
        $old = '{ "target": { "type": "usb", "label": "STARY" }, "folders": ["C:\\Dane", "D:\\B"], "excludes": ["*.tmp"], "schedule": { "time": "12:30" }, "retention": { "daily": 30, "weekly": 4, "monthly": 2 } }'
        $new = Update-DailyConfigJson -Json $old -Type smb -Share '\\nas\share' -User 'uzytkownik' -Folder 'WinResurectDaily' -Time '14:15'
        $p = Join-Path $TestDrive 'upd.json'
        Set-Content -LiteralPath $p -Value $new -Encoding UTF8
        $c = Read-DailyConfig -Path $p
        $c.Target.Type | Should -Be 'smb'
        $c.Time | Should -Be '14:15'
        @($c.Folders) | Should -Be @('C:\Dane', 'D:\B')
        @($c.Excludes) | Should -Be @('*.tmp')
        $c.Retention.Daily | Should -Be 30
        $c.Retention.Monthly | Should -Be 2
    }
}

Describe 'entry scripts for the daily backup' {
    It 'reports a not-installed copy from Status with exit code 2 (no Windows calls before the check)' {
        $dir = Join-Path $TestDrive 'pusty'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $old = $env:WINRES_HOME
        try {
            $env:WINRES_HOME = $dir
            $pwsh = (Get-Process -Id $PID).Path
            & $pwsh -NoProfile -File (Join-Path $script:root 'Get-DailyStatus.ps1') -Root $script:root *> $null
            $LASTEXITCODE | Should -Be 2
        }
        finally { if ($null -ne $old) { $env:WINRES_HOME = $old } else { Remove-Item Env:WINRES_HOME -ErrorAction SilentlyContinue } }
    }

    It 'rejects bad install parameters with exit code 2 before touching the system' {
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoProfile -File (Join-Path $script:root 'Install-DailyBackup.ps1') -Root $script:root -Target usb -Label 'zły/label' *> $null
        $LASTEXITCODE | Should -Be 2
    }
}


Describe 'review fixes: robustness of the job' {
    BeforeAll {
        $script:usbVol3 = @([pscustomobject]@{ Drive = 'E:'; Label = 'BACKUP'; FileSystem = 'NTFS'; DriveType = 3 })
        function Invoke-RobustJob {
            param([scriptblock]$Reader = { $null }, [scriptblock]$Connector = $null, $Config = (New-TestDailyConfig))
            if (-not $Connector) { $Connector = { param($s, $u, $p) @{ ExitCode = 0; Output = @() } } }
            Invoke-DailyJob -Mode backup -Config $Config -Volumes $script:usbVol3 -Runner $script:runner3 -WorkDir $script:work3 `
                -ReadSmbCredential $Reader -Connector $Connector -PathExists { param($p) $true } `
                -Clock { [datetime]::SpecifyKind([datetime]'2026-10-14T10:30:00', 'Utc') } -ComputerName 'PC1'
        }
    }
    BeforeEach {
        $script:work3 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work3 | Out-Null
        $script:runner3 = { param($Exe, $ArgList) @{ ExitCode = 0; Output = @('{"message_type":"summary","data_added":1,"snapshot_id":"abcdef012345"}') } }
    }

    It 'records an unexpected exception as a failed run (and keeps the previous last_success)' {
        $ok = Invoke-RobustJob
        $ok.Status | Should -Be 'ok'
        $good = (Read-LastRun -Path (Join-Path $script:work3 'last-run.json')).last_success
        $smb = New-TestDailyConfig -Target @{ Type = 'smb'; Label = ''; Share = '\\nas\share'; User = 'u'; Folder = 'WinResurectDaily' }
        $r = Invoke-RobustJob -Config $smb -Reader { throw 'DPAPI: nie można odszyfrować' }
        $r.ExitCode | Should -Be 1
        $r.Status | Should -Be 'fail'
        $lr = Read-LastRun -Path (Join-Path $script:work3 'last-run.json')
        $lr.status | Should -Be 'fail'
        $lr.note | Should -Match 'nieoczekiwany błąd'
        $lr.last_success | Should -Be $good
        (Get-Content -LiteralPath (Join-Path $script:work3 'daily.log') -Raw) | Should -Match 'nieoczekiwany'
    }

    It 'records an exception from the connector as a failed run' {
        $smb = New-TestDailyConfig -Target @{ Type = 'smb'; Label = ''; Share = '\\nas\share'; User = 'u'; Folder = 'WinResurectDaily' }
        $cred = New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'Sekret1' -AsPlainText -Force))
        $r = Invoke-RobustJob -Config $smb -Reader { $cred }.GetNewClosure() -Connector { throw 'csc.exe zablokowany przez antywirus' }
        $r.ExitCode | Should -Be 1
        $r.LastRun.note | Should -Match 'antywirus'
        $r.LastRun.note | Should -Not -Match 'Sekret1'
    }

    It 'writes a start line to the log immediately so that pollers see activity' {
        Invoke-RobustJob | Out-Null
        (Get-Content -LiteralPath (Join-Path $script:work3 'daily.log') -Raw) | Should -Match 'Start'
    }
}

Describe 'review fixes: status tolerates damaged files' {
    It 'treats a last-run file with the wrong shape as missing' {
        $p = Join-Path $TestDrive 'lr.json'
        foreach ($bad in '{}', '"x"', '[]', '42', 'null') {
            Set-Content -LiteralPath $p -Value $bad -Encoding UTF8
            Read-LastRun -Path $p | Should -BeNullOrEmpty
        }
    }

    It 'prints a status text for a partial last-run without throwing' {
        $partial = [pscustomobject]@{ status = 'ok' }
        { Get-DailyStatusText -LastRun $partial -Now ([datetime]'2026-10-14T12:00:00') } | Should -Not -Throw
        (Get-DailyStatusText -LastRun $partial -Now ([datetime]'2026-10-14T12:00:00')) | Should -Match 'NIEAKTUALNA'
        { Get-DailyStaleness -LastRun $partial -Now ([datetime]'2026-10-14T12:00:00') } | Should -Not -Throw
    }

    It 'accepts last_success parsed as a datetime (PowerShell 7) as well as a string' {
        $now = [datetime]::SpecifyKind([datetime]'2026-10-14T12:00:00', 'Utc')
        $asDate = [pscustomobject]@{ status = 'ok'; last_success = [datetime]::SpecifyKind([datetime]'2026-10-14T10:00:00', 'Utc') }
        Get-DailyStaleness -LastRun $asDate -Now $now | Should -Be 'fresh'
        $asText = [pscustomobject]@{ status = 'ok'; last_success = '2026-10-10T10:00:00Z' }
        Get-DailyStaleness -LastRun $asText -Now $now | Should -Be 'stale'
    }
}

Describe 'review fixes: JSON lists in Windows PowerShell 5.1' {
    It 'expands a list that arrives wrapped in one array (5.1 behaviour) as well as flat lists' {
        $a = [pscustomobject]@{ n = 1 }; $b = [pscustomobject]@{ n = 2 }
        @(Expand-JsonItems -Parsed (, @($a, $b))).Count | Should -Be 2
        @(Expand-JsonItems -Parsed @($a, $b)).Count | Should -Be 2
        @(Expand-JsonItems -Parsed $a).Count | Should -Be 1
        @(Expand-JsonItems -Parsed $null).Count | Should -Be 0
    }

    It 'reads no snapshots from a literal null' {
        @(ConvertFrom-ResticSnapshots -Json 'null').Count | Should -Be 0
    }
}

Describe 'review fixes: paths and config updates' {
    It 'normalizes trailing backslashes (restic receives them badly from Windows PowerShell 5.1)' {
        ConvertTo-ResticFolder -Path 'D:\Dane Firmy\' | Should -Be 'D:\Dane Firmy'
        ConvertTo-ResticFolder -Path 'D:\' | Should -Be 'D:\'
        ConvertTo-ResticFolder -Path '\\nas\share\x\' | Should -Be '\\nas\share\x'
        $c = Read-DailyConfig -Path (Write-TestJson 'tb.json' (New-RawConfig @{ folders = @('D:\Dane Firmy\') }))
        @($c.Folders) | Should -Be @('D:\Dane Firmy')
        $a = @(Get-DailyBackupArgs -Config (New-TestDailyConfig) -Folders @('D:\Dane Firmy\') -ComputerName 'PC1')
        $a[-1] | Should -Be 'D:\Dane Firmy'
    }

    It 'keeps time and folder on update when they are not given, and overrides them when they are' {
        $old = '{ "target": { "type": "usb", "label": "STARY", "folder": "Kopie" }, "folders": ["C:\\Dane"], "schedule": { "time": "07:00" } }'
        $kept = Update-DailyConfigJson -Json $old -Type usb -Label 'NOWY'
        $p = Join-Path $TestDrive 'keep.json'
        Set-Content -LiteralPath $p -Value $kept -Encoding UTF8
        $c = Read-DailyConfig -Path $p
        $c.Target.Label | Should -Be 'NOWY'
        $c.Target.Folder | Should -Be 'Kopie'
        $c.Time | Should -Be '07:00'
        $changed = Update-DailyConfigJson -Json $old -Type usb -Label 'NOWY' -Time '14:15' -Folder 'Inny'
        Set-Content -LiteralPath $p -Value $changed -Encoding UTF8
        $c2 = Read-DailyConfig -Path $p
        $c2.Time | Should -Be '14:15'
        $c2.Target.Folder | Should -Be 'Inny'
    }

    It 'rejects control characters in the SMB user name' {
        { Test-DailyTargetParams -Target smb -Share '\\nas\share' -User ("jan" + [char]7) } | Should -Throw
        (Test-DailyTargetParams -Target smb -Share '\\nas\share' -User "o'neil").User | Should -Be "o'neil"
    }
}

Describe 'review fixes: the SYSTEM script and its quoting' {
    It 'quotes any text into a PowerShell single-quoted literal that round-trips' {
        foreach ($text in @("zwykły", "o'neil", 'a$b`c"d', ("smart " + [char]0x2019 + " quote"), "x'); Write-Host pwn; ('")) {
            $q = ConvertTo-SingleQuoted -Text $text
            $back = & ([scriptblock]::Create($q))
            $back | Should -Be $text
        }
    }

    It 'builds a SetCred script that stops on errors, reads the password as UTF-8 untrimmed, and cannot be injected' {
        foreach ($user in @('jan', "o'neil", "x'); Write-Host pwn; ('")) {
            $text = Get-SetCredScript -TmpPath 'C:\ProgramData\WinResurect\smb.tmp' -CredPath 'C:\ProgramData\WinResurect\smb.cred' -User $user
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
            $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
            $cmds | Should -Not -Contain 'Write-Host'
            ($cmds | Sort-Object -Unique) | Should -Be @('ConvertFrom-SecureString', 'ConvertTo-SecureString', 'Remove-Item', 'Set-Content')
            $text | Should -Match "ErrorActionPreference = 'Stop'"
            $text | Should -Match 'ReadAllText'
            $text | Should -Not -Match '\.Trim\(\)'
        }
    }

    It 'builds the scheduled-task argument so that the script log is really written and the exit code is passed on' {
        $arg = Get-AsSystemArgument -Script 'C:\ProgramData\WinResurect\x.ps1' -Log 'C:\ProgramData\WinResurect\x.log'
        $arg | Should -Match '^-NoProfile -ExecutionPolicy Bypass -Command "'
        $arg | Should -Match "& 'C:\\ProgramData\\WinResurect\\x\.ps1' \*> 'C:\\ProgramData\\WinResurect\\x\.log'"
        $arg | Should -Match 'exit \$LASTEXITCODE'
        $arg | Should -Not -Match ' -File '
    }
}

Describe 'review fixes: install safety' {
    It 'trusts only SYSTEM, Administrators and TrustedInstaller as owners (by SID, not by localized name)' {
        Test-TrustedOwnerSid -Sid 'S-1-5-18' | Should -BeTrue
        Test-TrustedOwnerSid -Sid 'S-1-5-32-544' | Should -BeTrue
        Test-TrustedOwnerSid -Sid 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' | Should -BeTrue
        Test-TrustedOwnerSid -Sid 'S-1-5-21-111-222-333-1001' | Should -BeFalse
        Test-TrustedOwnerSid -Sid '' | Should -BeFalse
    }

    It 'names the exact restic executable inside the archive' {
        Get-ResticExeName -Version '0.19.1' | Should -Be 'restic_0.19.1_windows_amd64.exe'
    }

    It 'collects every install precondition before anything is changed' {
        @(Get-InstallPreflightErrors -IsAdmin $true -Is64Bit $true -TargetOk $true).Count | Should -Be 0
        $e = @(Get-InstallPreflightErrors -IsAdmin $false -Is64Bit $false -TargetOk $false -TargetReason 'cel niedostępny: brak dysku' -WorkDirTrusted $false -WorkDir 'C:\ProgramData\WinResurect')
        ($e -join ' ') | Should -Match 'administrator'
        ($e -join ' ') | Should -Match '64'
        ($e -join ' ') | Should -Match 'cel niedostępny: brak dysku'
        ($e -join ' ') | Should -Match 'C:\\ProgramData\\WinResurect'
        $e.Count | Should -Be 4
    }
}

Describe 'review fixes: restore target outside the backed-up folders' {
    It 'picks the first candidate base that does not collide with the backed-up folders' {
        $folders = @('C:\Users\Jan\Documents', 'C:\Users\Jan\Desktop')
        $now = [datetime]'2026-10-14T13:05:00'
        Select-SafeRestoreBase -Candidates @('C:\Users\Jan\Desktop', 'C:\') -Folders $folders -Now $now | Should -Be 'C:\'
        Select-SafeRestoreBase -Candidates @('C:\Users\Jan\Downloads', 'C:\') -Folders $folders -Now $now | Should -Be 'C:\Users\Jan\Downloads'
        Select-SafeRestoreBase -Candidates @('C:\Users\Jan\Desktop') -Folders $folders -Now $now | Should -BeNullOrEmpty
    }
}
