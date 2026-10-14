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
