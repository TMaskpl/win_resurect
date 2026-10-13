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
