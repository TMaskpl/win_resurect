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
