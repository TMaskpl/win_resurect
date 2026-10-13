BeforeAll {
    $script:modulePath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'WinResurect.psm1'
    Import-Module $script:modulePath -Force
}

Describe 'Test-ResurectParams' {
    It 'normalizes a USB drive letter' {
        (Test-ResurectParams -Target usb -Drive 'e').Drive | Should -Be 'E:'
        (Test-ResurectParams -Target usb -Drive 'E:').Drive | Should -Be 'E:'
    }

    It 'rejects a bad USB drive' {
        { Test-ResurectParams -Target usb -Drive 'EE' } | Should -Throw '*liter*'
        { Test-ResurectParams -Target usb -Drive '' } | Should -Throw
        { Test-ResurectParams -Target usb -Drive '1:' } | Should -Throw
    }

    It 'accepts an SMB share and user, trims the trailing backslash, keeps subpaths' {
        $p = Test-ResurectParams -Target smb -Share '\\nas\share\' -User 'uzytkownik'
        $p.Share | Should -Be '\\nas\share'
        $p.User | Should -Be 'uzytkownik'
        (Test-ResurectParams -Target smb -Share '\\nas\share\katalog' -User 'u').Share | Should -Be '\\nas\share\katalog'
    }

    It 'rejects a non-UNC share and a missing user' {
        { Test-ResurectParams -Target smb -Share 'nas/share' -User 'u' } | Should -Throw '*udział*'
        { Test-ResurectParams -Target smb -Share '\\nas\share' -User '' } | Should -Throw '*użytkownika*'
    }

    It 'rejects an unknown target' {
        { Test-ResurectParams -Target dvd } | Should -Throw
    }

    It 'rejects dangerous folder names and accepts normal ones' {
        foreach ($bad in '..', '.', 'a\b', 'a/b', 'a b', '') {
            { Test-ResurectParams -Target usb -Drive 'E:' -Folder $bad } | Should -Throw
        }
        (Test-ResurectParams -Target usb -Drive 'E:' -Folder 'kopie-2026').Folder | Should -Be 'kopie-2026'
        (Test-ResurectParams -Target usb -Drive 'E:').Folder | Should -Be 'WinResurect'
    }
}

Describe 'Get-ImageTarget' {
    It 'puts a USB image in the drive root and documents in a dated folder' {
        $p = [pscustomobject]@{ Target = 'usb'; Drive = 'E:'; Share = ''; User = ''; Folder = 'WinResurect' }
        $t = Get-ImageTarget -Params $p -ComputerName 'PC1' -Now ([datetime]'2026-10-13T09:40:00')
        $t.BackupTarget | Should -Be 'E:'
        $t.DocDir | Should -Be 'E:\WinResurect\PC1_2026-10-13_0940'
        $t.ImageRoot | Should -Be 'E:\WindowsImageBackup\PC1'
    }

    It 'uses a new dated subfolder on an SMB share for both image and documents' {
        $p = [pscustomobject]@{ Target = 'smb'; Drive = ''; Share = '\\nas\share'; User = 'u'; Folder = 'WinResurect' }
        $t = Get-ImageTarget -Params $p -ComputerName 'PC1' -Now ([datetime]'2026-10-13T09:40:00')
        $t.BackupTarget | Should -Be '\\nas\share\WinResurect\PC1_2026-10-13_0940'
        $t.DocDir | Should -Be $t.BackupTarget
        $t.ImageRoot | Should -Be '\\nas\share\WinResurect\PC1_2026-10-13_0940\WindowsImageBackup\PC1'
    }
}

Describe 'Get-WbadminArgs' {
    It 'builds the image command for several volumes' {
        $a = Get-WbadminArgs -BackupTarget 'E:' -Volumes @('C:', 'D:')
        $a | Should -Be @('start', 'backup', '-backupTarget:E:', '-include:C:,D:', '-allCritical', '-quiet')
    }
}

Describe 'volume selection' {
    BeforeAll {
        $script:vols = @(
            [pscustomobject]@{ Drive = 'C:'; FileSystem = 'NTFS'; DriveType = 3; Size = [long]500GB; Free = [long]300GB; Used = [long]200GB },
            [pscustomobject]@{ Drive = 'D:'; FileSystem = 'NTFS'; DriveType = 3; Size = [long]500GB; Free = [long]400GB; Used = [long]100GB },
            [pscustomobject]@{ Drive = 'E:'; FileSystem = 'NTFS'; DriveType = 3; Size = [long]2000GB; Free = [long]1900GB; Used = [long]100GB },
            [pscustomobject]@{ Drive = 'F:'; FileSystem = 'FAT32'; DriveType = 3; Size = [long]32GB; Free = [long]30GB; Used = [long]2GB },
            [pscustomobject]@{ Drive = 'G:'; FileSystem = 'NTFS'; DriveType = 5; Size = [long]1GB; Free = [long]0; Used = [long]1GB }
        )
    }

    It 'takes local fixed NTFS volumes except the target' {
        @(Select-BackupVolumes -Volumes $script:vols -TargetDrive 'E:') | Should -Be @('C:', 'D:')
    }

    It 'takes every eligible volume when there is no local target' {
        @(Select-BackupVolumes -Volumes $script:vols) | Should -Be @('C:', 'D:', 'E:')
    }

    It 'sums used bytes of the selected volumes only' {
        Get-UsedBytes -Volumes $script:vols -Selected @('C:', 'D:') | Should -Be ([long]300GB)
    }
}

Describe 'Test-Preflight' {
    BeforeAll {
        function New-TestFacts {
            param([hashtable]$Overrides = @{})
            $f = [ordered]@{
                IsAdmin = $true; HasWbadmin = $true; Volumes = @('C:'); Target = 'usb'; TargetFound = $true
                TargetFileSystem = 'NTFS'; TargetIsSystemDisk = $false; TargetFreeBytes = [long]500GB; UsedBytes = [long]100GB
                OnBattery = $false; BitLockerProtected = $false; BitLockerKeyConfirmed = $false
                TargetIsSystemDrive = $false; TargetDiskUnknown = $false
            }
            foreach ($k in $Overrides.Keys) { $f[$k] = $Overrides[$k] }
            [pscustomobject]$f
        }
    }

    It 'passes for a healthy USB setup' {
        $r = Test-Preflight -Facts (New-TestFacts)
        $r.Errors.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 0
    }

    It 'requires administrator and wbadmin and at least one volume' {
        (Test-Preflight -Facts (New-TestFacts @{ IsAdmin = $false })).Errors -join ' ' | Should -Match 'administrator'
        (Test-Preflight -Facts (New-TestFacts @{ HasWbadmin = $false })).Errors -join ' ' | Should -Match 'wbadmin'
        (Test-Preflight -Facts (New-TestFacts @{ Volumes = @() })).Errors -join ' ' | Should -Match 'woluminów'
    }

    It 'requires the USB disk to exist, be NTFS and not share the system disk' {
        (Test-Preflight -Facts (New-TestFacts @{ TargetFound = $false })).Errors -join ' ' | Should -Match 'Nie znaleziono'
        (Test-Preflight -Facts (New-TestFacts @{ TargetFileSystem = 'FAT32' })).Errors -join ' ' | Should -Match 'NTFS'
        (Test-Preflight -Facts (New-TestFacts @{ TargetIsSystemDisk = $true })).Errors -join ' ' | Should -Match 'fizycznym dysku'
    }

    It 'needs 10 percent more free space than used space' {
        $r = Test-Preflight -Facts (New-TestFacts @{ TargetFreeBytes = [long]105GB })
        $r.Errors -join ' ' | Should -Match 'Za mało miejsca'
        (Test-Preflight -Facts (New-TestFacts @{ TargetFreeBytes = [long]110GB })).Errors.Count | Should -Be 0
    }

    It 'only warns when free space on the target is unknown (SMB)' {
        $r = Test-Preflight -Facts (New-TestFacts @{ Target = 'smb'; TargetFound = $true; TargetFileSystem = ''; TargetFreeBytes = $null })
        $r.Errors.Count | Should -Be 0
        $r.Warnings -join ' ' | Should -Match 'wolnego miejsca'
    }

    It 'refuses the system drive as the USB target and warns when the target disk cannot be identified' {
        (Test-Preflight -Facts (New-TestFacts @{ TargetIsSystemDrive = $true })).Errors -join ' ' | Should -Match 'systemow'
        $r = Test-Preflight -Facts (New-TestFacts @{ TargetDiskUnknown = $true })
        $r.Errors.Count | Should -Be 0
        $r.Warnings -join ' ' | Should -Match 'fizyczn'
    }

    It 'reports a missing volume list instead of failing on empty input' {
        @(Select-BackupVolumes -Volumes @()).Count | Should -Be 0
        Get-UsedBytes -Volumes @() -Selected @() | Should -Be 0
    }

    It 'warns on battery' {
        (Test-Preflight -Facts (New-TestFacts @{ OnBattery = $true })).Warnings -join ' ' | Should -Match 'bateri'
    }

    It 'blocks BitLocker without a confirmed recovery key and allows it with one' {
        $blocked = Test-Preflight -Facts (New-TestFacts @{ BitLockerProtected = $true })
        $blocked.Errors -join ' ' | Should -Match 'BitLocker'
        (Test-Preflight -Facts (New-TestFacts @{ BitLockerProtected = $true; BitLockerKeyConfirmed = $true })).Errors.Count | Should -Be 0
    }
}

Describe 'Format-Size' {
    It 'formats with invariant culture' {
        Format-Size -Bytes ([long]1.5GB) | Should -Be '1.5 GB'
        Format-Size -Bytes ([long]5MB) | Should -Be '5 MB'
        Format-Size -Bytes 2048 | Should -Be '2 KB'
    }
}

Describe 'Hide-Secrets' {
    It 'masks known secrets and password arguments' {
        $t = Hide-Secrets -Text 'wbadmin ... -password:Sekret1 oraz Sekret1 i /pass:abc' -Secrets @('Sekret1')
        $t | Should -Not -Match 'Sekret1'
        $t | Should -Match '-password:\*\*\*'
        $t | Should -Match '/pass:\*\*\*'
    }

    It 'leaves ordinary text alone and handles empty input' {
        Hide-Secrets -Text 'Wszystko w porządku' -Secrets @('Sekret1') | Should -Be 'Wszystko w porządku'
        Hide-Secrets -Text '' | Should -Be ''
    }

    It 'ignores very short secrets so it does not mangle text' {
        Hide-Secrets -Text 'ab cd' -Secrets @('a') | Should -Be 'ab cd'
    }
}

Describe 'documents' {
    BeforeAll {
        $script:info = [pscustomobject]@{
            ToolVersion = '0.1.0'; ComputerName = 'PC1'; OsCaption = 'Microsoft Windows 11 Pro'; OsVersion = '10.0.26100'
            Date = [datetime]'2026-10-13T09:40:00'; Target = 'usb'; Drive = 'E:'; BackupTarget = 'E:'
            Status = 'OK'; DurationSec = 754.4; BitLocker = $true
            Volumes = @([pscustomobject]@{ Drive = 'C:'; Used = [long]1.5GB })
        }
    }

    It 'writes a manifest with the essentials and no key material' {
        $m = New-Manifest -Info $script:info
        $m | Should -Match 'Komputer: PC1'
        $m | Should -Match 'Wynik: OK'
        $m | Should -Match 'C:\s+użyte: 1\.5 GB'
        $m | Should -Match '2026-10-13 09:40'
        $m | Should -Match 'BitLocker: tak'
        $m | Should -Match 'klucz nie jest zapisywany'
    }

    It 'writes restore instructions for a USB copy' {
        $t = New-RestoreInstructions -Info $script:info
        $t | Should -Match 'PC1'
        $t | Should -Match 'dysk USB E:'
        $t | Should -Match 'Odzyskiwanie obrazu systemu'
        $t | Should -Match 'Mount-DiskImage'
        $t | Should -Match 'klucz odzyskiwania BitLocker'
    }

    It 'writes restore instructions for an SMB copy that name the share but no credentials' {
        $i = $script:info.PSObject.Copy()
        $i.Target = 'smb'
        $i.BackupTarget = '\\nas\share\WinResurect\PC1_2026-10-13_0940'
        $t = New-RestoreInstructions -Info $i
        $t | Should -Match 'nas\\share\\WinResurect\\PC1_2026-10-13_0940'
        $t | Should -Match 'Wyszukaj obraz systemu w sieci'
        $t | Should -Not -Match '(?i)hasło:|password'
    }

    It 'detects whether an image file exists' {
        $root = Join-Path $TestDrive 'img'
        Test-ImageFilePresent -Root $root | Should -BeFalse
        New-Item -ItemType Directory -Path $root | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'pusty.vhdx') | Out-Null
        Test-ImageFilePresent -Root $root | Should -BeFalse
        Set-Content -Path (Join-Path $root 'obraz.vhdx') -Value 'x'
        Test-ImageFilePresent -Root $root | Should -BeTrue
    }
}

Describe 'Invoke-ResurectBackup' {
    BeforeAll {
        $script:paramsUsb = [pscustomobject]@{ Target = 'usb'; Drive = 'E:'; Share = ''; User = ''; Folder = 'WinResurect' }
        $script:paramsSmb = [pscustomobject]@{ Target = 'smb'; Drive = ''; Share = '\\nas\share'; User = 'uzytkownik'; Folder = 'WinResurect' }
        function New-OrchFacts {
            param([hashtable]$Overrides = @{})
            $f = [ordered]@{
                IsAdmin = $true; HasWbadmin = $true; Volumes = @('C:'); Target = 'usb'; TargetFound = $true
                TargetFileSystem = 'NTFS'; TargetIsSystemDisk = $false; TargetFreeBytes = [long]500GB; UsedBytes = [long]100GB
                OnBattery = $false; BitLockerProtected = $false; BitLockerKeyConfirmed = $false
                TargetIsSystemDrive = $false; TargetDiskUnknown = $false
            }
            foreach ($k in $Overrides.Keys) { $f[$k] = $Overrides[$k] }
            [pscustomobject]$f
        }
        function New-TestCredential([string]$User, [string]$Pass) {
            New-Object System.Management.Automation.PSCredential($User, (ConvertTo-SecureString $Pass -AsPlainText -Force))
        }
        function Invoke-Orch {
            param($Params, $Facts, [string]$Pass = '', $Skipped = @())
            $extra = @{}
            if ($Pass) { $extra['Credential'] = New-TestCredential 'uzytkownik' $Pass }
            Invoke-ResurectBackup -Params $Params -Target $script:target -Facts $Facts -Volumes @('C:') -Runner $script:runner `
                -Connector $script:connector -Disconnector $script:disconnector `
                -ComputerName 'PC1' -Now ([datetime]'2026-10-13T09:40:00') -OsCaption 'Windows 11' -OsVersion '10.0' `
                -VolumeInfo $script:vinfo -SkippedInfo $Skipped @extra
        }
    }
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:imageRoot = Join-Path $script:root 'WindowsImageBackup'
        $script:target = [pscustomobject]@{ BackupTarget = 'E:'; DocDir = (Join-Path $script:root 'doc'); ImageRoot = $script:imageRoot; Leaf = 'PC1_x' }
        $script:calls = New-Object System.Collections.ArrayList
        $script:seenPassword = $null
        $script:wbFail = $false; $script:netFail = $false; $script:pnpFail = $false; $script:noImage = $false
        $script:runner = {
            param($Exe, $ArgList)
            $script:calls.Add(("$Exe " + ($ArgList -join ' '))) | Out-Null
            if ($Exe -eq 'wbadmin' -and $ArgList[0] -eq 'start') {
                if ($script:wbFail) { return @{ ExitCode = 5; Output = @('Błąd: brak miejsca', 'szczegóły -password:Sekret1') } }
                if (-not $script:noImage) {
                    New-Item -ItemType Directory -Force -Path $script:imageRoot | Out-Null
                    Set-Content -Path (Join-Path $script:imageRoot 'obraz.vhdx') -Value 'x'
                }
                return @{ ExitCode = 0; Output = @() }
            }
            if ($Exe -eq 'wbadmin' -and $ArgList[0] -eq 'get') { return @{ ExitCode = 0; Output = @('Identyfikator wersji: 10/13/2026-09:40') } }
            if ($Exe -eq 'pnputil' -and $script:pnpFail) { return @{ ExitCode = 1; Output = @() } }
            return @{ ExitCode = 0; Output = @() }
        }
        $script:connector = {
            param($Share, $User, $Password)
            $script:calls.Add("connect $Share $User") | Out-Null
            $script:seenPassword = $Password
            if ($script:netFail) { return @{ ExitCode = 53; Output = @('Błąd systemu 53') } }
            return @{ ExitCode = 0; Output = @() }
        }
        $script:disconnector = {
            param($Share)
            $script:calls.Add("disconnect $Share") | Out-Null
            return @{ ExitCode = 0; Output = @() }
        }
        $script:vinfo = @([pscustomobject]@{ Drive = 'C:'; Used = [long]1GB })
    }

    It 'backs up to USB: drivers, image, verification, documents, no network calls' {
        $r = Invoke-Orch $script:paramsUsb (New-OrchFacts)
        $r.ExitCode | Should -Be 0
        $r.Status | Should -Be 'OK'
        @($script:calls) | Should -Be @(
            "pnputil /export-driver * $(Join-Path $script:target.DocDir 'drivers')",
            'wbadmin start backup -backupTarget:E: -include:C: -allCritical -quiet',
            'wbadmin get versions -backupTarget:E:')
        foreach ($f in 'manifest.txt', 'log.txt', 'PRZYWRACANIE.txt') { Test-Path (Join-Path $script:target.DocDir $f) | Should -BeTrue }
        Test-Path (Join-Path $script:target.DocDir 'drivers') | Should -BeTrue
    }

    It 'connects to SMB through the connector, never through a command line, and never leaks the password' {
        $facts = New-OrchFacts @{ Target = 'smb'; TargetFileSystem = ''; TargetFreeBytes = $null }
        $r = Invoke-Orch $script:paramsSmb $facts 'Sekret1'
        $r.ExitCode | Should -Be 0
        $script:calls[0] | Should -Be 'connect \\nas\share uzytkownik'
        $script:calls[-1] | Should -Be 'disconnect \\nas\share'
        $script:seenPassword | Should -Be 'Sekret1'
        (@($script:calls) -join "`n") | Should -Not -Match 'Sekret1'
        (@($script:calls) -join "`n") | Should -Not -Match '(?m)^net '
        $all = (Get-ChildItem $script:target.DocDir -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $all | Should -Not -Match 'Sekret1'
        ($r.Messages -join "`n") | Should -Not -Match 'Sekret1'
    }

    It 'stops before touching anything when preflight fails' {
        $r = Invoke-Orch $script:paramsUsb (New-OrchFacts @{ IsAdmin = $false })
        $r.ExitCode | Should -Be 2
        $script:calls.Count | Should -Be 0
        Test-Path $script:target.DocDir | Should -BeFalse
    }

    It 'requires credentials for SMB' {
        $facts = New-OrchFacts @{ Target = 'smb'; TargetFileSystem = ''; TargetFreeBytes = $null }
        $r = Invoke-Orch $script:paramsSmb $facts ''
        $r.ExitCode | Should -Be 2
        $script:calls.Count | Should -Be 0
    }

    It 'stops with code 2 when the share cannot be connected and runs no image command' {
        $script:netFail = $true
        $facts = New-OrchFacts @{ Target = 'smb'; TargetFileSystem = ''; TargetFreeBytes = $null }
        $r = Invoke-Orch $script:paramsSmb $facts 'Sekret1'
        $r.ExitCode | Should -Be 2
        $script:calls.Count | Should -Be 1
        ($r.Messages -join "`n") | Should -Not -Match 'Sekret1'
        ($r.Messages -join "`n") | Should -Match '53'
        Test-Path $script:target.DocDir | Should -BeFalse
    }

    It 'reports code 1 when wbadmin fails: masked log, error manifest, no restore instructions, share disconnected' {
        $script:wbFail = $true
        $facts = New-OrchFacts @{ Target = 'smb'; TargetFileSystem = ''; TargetFreeBytes = $null }
        $r = Invoke-Orch $script:paramsSmb $facts 'Sekret1'
        $r.ExitCode | Should -Be 1
        $log = Get-Content -LiteralPath (Join-Path $script:target.DocDir 'log.txt') -Raw
        $log | Should -Not -Match 'Sekret1'
        $log | Should -Match 'brak miejsca'
        (Get-Content -LiteralPath (Join-Path $script:target.DocDir 'manifest.txt') -Raw) | Should -Match 'Wynik: BŁĄD'
        Test-Path (Join-Path $script:target.DocDir 'PRZYWRACANIE.txt') | Should -BeFalse
        $script:calls[-1] | Should -Be 'disconnect \\nas\share'
    }

    It 'fails verification when no image file appears' {
        $script:noImage = $true
        $r = Invoke-Orch $script:paramsUsb (New-OrchFacts)
        $r.ExitCode | Should -Be 1
        Test-Path (Join-Path $script:target.DocDir 'PRZYWRACANIE.txt') | Should -BeFalse
    }

    It 'does not accept an image from an earlier visit as proof of the new copy' {
        New-Item -ItemType Directory -Force -Path $script:imageRoot | Out-Null
        $old = Join-Path $script:imageRoot 'stary.vhdx'
        Set-Content -Path $old -Value 'x'
        (Get-Item -LiteralPath $old).LastWriteTime = [datetime]'2020-01-01T00:00:00'
        $script:noImage = $true
        $r = Invoke-Orch $script:paramsUsb (New-OrchFacts)
        $r.ExitCode | Should -Be 1
        $r.Status | Should -Match 'weryfikacja'
    }

    It 'treats a driver export failure as a warning only' {
        $script:pnpFail = $true
        $r = Invoke-Orch $script:paramsUsb (New-OrchFacts)
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:target.DocDir 'log.txt') -Raw) | Should -Match 'sterowników'
    }

    It 'records skipped volumes in the log and the manifest' {
        $skipped = @([pscustomobject]@{ Drive = 'D:'; Reason = 'zablokowany BitLocker' })
        $r = Invoke-Orch $script:paramsUsb (New-OrchFacts) '' $skipped
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:target.DocDir 'log.txt') -Raw) | Should -Match 'D:.*zablokowany BitLocker'
        (Get-Content -LiteralPath (Join-Path $script:target.DocDir 'manifest.txt') -Raw) | Should -Match 'Pominięte woluminy'
    }
}

Describe 'script encoding' {
    It 'keeps PowerShell sources as UTF-8 with BOM so Windows PowerShell 5.1 reads Polish text correctly' {
        $root = Split-Path $PSScriptRoot -Parent
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1, *.psm1 |
                Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' })
        $files.Count | Should -BeGreaterThan 1
        foreach ($f in $files) {
            $b = [System.IO.File]::ReadAllBytes($f.FullName)
            ('{0:X2}{1:X2}{2:X2}' -f $b[0], $b[1], $b[2]) | Should -Be 'EFBBBF' -Because "$($f.Name) musi mieć BOM UTF-8"
        }
    }

    It 'keeps Start.cmd ASCII-only with CRLF line endings' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path (Split-Path $PSScriptRoot -Parent) 'Start.cmd'))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        ($text -split "`n").Count | Should -BeGreaterThan 5
        $text | Should -Not -Match "[^\r]\n"
    }
}


Describe 'tool version and entry script' {
    It 'exposes the tool version through a function (module variables are private)' {
        Get-ToolVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'starts under StrictMode and rejects bad input with exit code 2 (run as a file)' {
        $root = Split-Path $PSScriptRoot -Parent
        $pwsh = (Get-Process -Id $PID).Path
        Push-Location $root
        try {
            & $pwsh -NoProfile -File (Join-Path $root 'Invoke-Resurect.ps1') -Target usb -Drive EE *> $null
            $LASTEXITCODE | Should -Be 2
        }
        finally { Pop-Location }
    }

    It 'also works when the script text is loaded as a scriptblock from the tool folder (GPO workaround)' {
        $root = Split-Path $PSScriptRoot -Parent
        $pwsh = (Get-Process -Id $PID).Path
        Push-Location $root
        try {
            & $pwsh -NoProfile -Command "& ([scriptblock]::Create((Get-Content -Raw .\Invoke-Resurect.ps1))) -Target usb -Drive EE" *> $null
            $LASTEXITCODE | Should -Be 2
        }
        finally { Pop-Location }
    }
}

Describe 'Start.cmd' {
    BeforeAll { $script:cmd = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Start.cmd') -Raw }

    It 'elevates without passing an empty argument list and without quoting paths into the command string' {
        $script:cmd | Should -Match 'if "%~1"==""'
        $script:cmd | Should -Match 'WINRES_SELF'
        $script:cmd | Should -Match 'WINRES_ARGS'
        $script:cmd | Should -Not -Match "-FilePath '%~f0'"
    }
}

Describe 'BitLocker state' {
    It 'treats active, suspended, in-progress and partially encrypted volumes as encrypted' {
        ConvertTo-BitLockerState -ProtectionStatus 1 -EncryptionPercentage 100 -VolumeStatus 'FullyEncrypted' | Should -Be 'On'
        ConvertTo-BitLockerState -ProtectionStatus 0 -EncryptionPercentage 100 -VolumeStatus 'FullyEncrypted' | Should -Be 'On'
        ConvertTo-BitLockerState -ProtectionStatus 0 -EncryptionPercentage 40 -VolumeStatus 'EncryptionInProgress' | Should -Be 'On'
    }

    It 'reports a decrypted volume as off' {
        ConvertTo-BitLockerState -ProtectionStatus 0 -EncryptionPercentage 0 -VolumeStatus 'FullyDecrypted' | Should -Be 'Off'
    }
}

Describe 'share root and skipped volumes' {
    It 'reduces a share path to its root' {
        Get-ShareRoot -Share '\\nas\share\katalog\pod' | Should -Be '\\nas\share'
        Get-ShareRoot -Share '\\nas\share' | Should -Be '\\nas\share'
    }

    It 'lists skipped volumes with a reason, except selected ones and the target' {
        $vols = @(
            [pscustomobject]@{ Drive = 'C:'; FileSystem = 'NTFS'; DriveType = 3; Size = [long]1GB; Free = [long]0; Used = [long]1GB },
            [pscustomobject]@{ Drive = 'D:'; FileSystem = ''; DriveType = 3; Size = [long]0; Free = [long]0; Used = [long]0 },
            [pscustomobject]@{ Drive = 'F:'; FileSystem = 'ReFS'; DriveType = 3; Size = [long]1GB; Free = [long]0; Used = [long]1GB },
            [pscustomobject]@{ Drive = 'G:'; FileSystem = 'NTFS'; DriveType = 2; Size = [long]1GB; Free = [long]0; Used = [long]1GB },
            [pscustomobject]@{ Drive = 'E:'; FileSystem = 'NTFS'; DriveType = 3; Size = [long]1GB; Free = [long]0; Used = [long]1GB }
        )
        $s = @(Get-SkippedVolumes -Volumes $vols -Selected @('C:') -TargetDrive 'E:')
        @($s | ForEach-Object { $_.Drive }) | Should -Be @('D:', 'F:', 'G:')
        ($s | Where-Object { $_.Drive -eq 'D:' }).Reason | Should -Match 'BitLocker'
        ($s | Where-Object { $_.Drive -eq 'F:' }).Reason | Should -Match 'ReFS'
        ($s | Where-Object { $_.Drive -eq 'G:' }).Reason | Should -Match 'wymienn'
    }

    It 'shows skipped volumes in the manifest' {
        $i = [pscustomobject]@{
            ToolVersion = '0.1.0'; ComputerName = 'PC1'; OsCaption = 'Windows'; OsVersion = '10'; Date = [datetime]'2026-10-13T09:40:00'
            Target = 'usb'; Drive = 'E:'; BackupTarget = 'E:'; Status = 'OK'; DurationSec = 1; BitLocker = $false
            Volumes = @(); Skipped = @([pscustomobject]@{ Drive = 'D:'; Reason = 'zablokowany BitLocker' })
        }
        (New-Manifest -Info $i) | Should -Match 'Pominięte woluminy:\s+D:.*zablokowany BitLocker'
    }
}

Describe 'fresh image check' {
    It 'ignores image files older than the given time' {
        $root = Join-Path $TestDrive 'fresh'
        New-Item -ItemType Directory -Path $root | Out-Null
        $f = Join-Path $root 'stary.vhdx'
        Set-Content -Path $f -Value 'x'
        (Get-Item -LiteralPath $f).LastWriteTime = [datetime]'2020-01-01T00:00:00'
        Test-ImageFilePresent -Root $root | Should -BeTrue
        Test-ImageFilePresent -Root $root -NotOlderThan ([datetime]'2026-01-01') | Should -BeFalse
        Set-Content -Path (Join-Path $root 'nowy.vhdx') -Value 'x'
        Test-ImageFilePresent -Root $root -NotOlderThan ([datetime]'2026-01-01') | Should -BeTrue
    }
}
