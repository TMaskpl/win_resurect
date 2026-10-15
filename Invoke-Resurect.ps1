[CmdletBinding()]
param(
    [ValidateSet('image', 'install-daily', 'status', 'restore', 'remove-daily', 'audit')][string]$Action,
    [ValidateSet('usb', 'smb')][string]$Target,
    [string]$Drive,
    [string]$Label,
    [string]$Share,
    [string]$User,
    [string]$Folder,
    [string]$Time,
    [switch]$Yes,
    [string]$Root
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = if ($Root) { $Root } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
foreach ($m in 'WinResurect.psm1', 'DailyBackup.psm1', 'Repair.psm1') {
    $modulePath = Join-Path (Join-Path $root 'src') $m
    try { Import-Module $modulePath -Force -ErrorAction Stop }
    catch { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $modulePath))) }
}

Write-Host "win_resurect $(Get-ToolVersion) - kopia całego systemu przed naprawą" -ForegroundColor Cyan

if (-not $Action) {
    if ($Target) { $Action = 'image' }
    else {
        Write-Host '1) Kopia całego systemu (obraz)'
        Write-Host '2) Zainstaluj lub zaktualizuj kopię codzienną'
        Write-Host '3) Status kopii codziennej'
        Write-Host '4) Przywróć pliki z kopii codziennej'
        Write-Host '5) Usuń kopię codzienną'
        Write-Host '6) Audyt systemu (tylko odczyt)'
        $choice = Read-Host 'Wybierz (1-6)'
        switch ($choice) {
            '1' { $Action = 'image' }
            '2' { $Action = 'install-daily' }
            '3' { $Action = 'status' }
            '4' { $Action = 'restore' }
            '5' { $Action = 'remove-daily' }
            '6' { $Action = 'audit' }
            default { Write-Host 'Przerwano.'; exit 3 }
        }
    }
}

if ($Action -ne 'image') {
    $files = @{ 'install-daily' = 'Install-DailyBackup.ps1'; 'status' = 'Get-DailyStatus.ps1'; 'restore' = 'Restore-DailyBackup.ps1'; 'remove-daily' = 'Remove-DailyBackup.ps1'; 'audit' = 'Get-WinAudit.ps1' }
    $splat = @{ Root = $root }
    if ($Action -eq 'install-daily') {
        foreach ($k in 'Target', 'Label', 'Share', 'User', 'Folder', 'Time') { if ((Get-Variable $k).Value) { $splat[$k] = (Get-Variable $k).Value } }
    }
    if ($Yes -and $Action -eq 'remove-daily') { $splat['Yes'] = $true }
    & ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $root $files[$Action])))) @splat
    exit 0
}

if (-not $Folder) { $Folder = 'WinResurect' }

if (-not $Target) {
    Write-Host '1) Dysk USB   2) Udział SMB'
    $choice = Read-Host 'Wybierz cel kopii (1/2)'
    if ($choice -eq '1') { $Target = 'usb' } elseif ($choice -eq '2') { $Target = 'smb' } else { Write-Host 'Przerwano.'; exit 3 }
}
if ($Target -eq 'usb' -and -not $Drive) { $Drive = Read-Host 'Litera dysku USB (np. E:)' }
if ($Target -eq 'smb') {
    if (-not $Share) { $Share = Read-Host 'Udział SMB (np. \\nas\share)' }
    if (-not $User) { $User = Read-Host 'Użytkownik udziału' }
}

try { $p = Test-ResurectParams -Target $Target -Drive $Drive -Share $Share -User $User -Folder $Folder }
catch { Write-Host "Błąd: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }

$credential = $null
if ($p.Target -eq 'smb') {
    if ($env:WINRES_PASSWORD) {
        $secure = ConvertTo-SecureString $env:WINRES_PASSWORD -AsPlainText -Force
        Remove-Item Env:WINRES_PASSWORD -ErrorAction SilentlyContinue
    }
    else { $secure = Read-Host "Hasło użytkownika $($p.User)" -AsSecureString }
    $credential = New-Object System.Management.Automation.PSCredential($p.User, $secure)
}

$all = @(Get-LocalVolumes)
$targetDrive = if ($p.Target -eq 'usb') { $p.Drive } else { '' }
$vols = @(Select-BackupVolumes -Volumes $all -TargetDrive $targetDrive)
$skipped = @(Get-SkippedVolumes -Volumes $all -Selected $vols -TargetDrive $targetDrive)
$facts = Get-ResurectFacts -Params $p -AllVolumes $all -Selected $vols

if ($skipped.Count -gt 0) {
    Write-Host 'Pominięte woluminy (NIE będą w kopii):' -ForegroundColor Yellow
    foreach ($sv in $skipped) { Write-Host "  $($sv.Drive)  $($sv.Reason)" -ForegroundColor Yellow }
}
if ($facts.BitLockerProtected) {
    Write-Host 'Wykryto BitLocker (lub nie udało się ustalić jego stanu). Bez klucza odzyskiwania odtworzony dysk może być niedostępny.' -ForegroundColor Yellow
    $a = Read-Host 'Czy klucz odzyskiwania jest zapisany poza tym komputerem i tą kopią? (T/N)'
    $facts.BitLockerKeyConfirmed = ($a -match '^[TtYy]')
}
if ($facts.OnBattery -and -not $Yes) {
    $a = Read-Host 'Komputer pracuje na baterii. Kontynuować? (T/N)'
    if ($a -notmatch '^[TtYy]') { Write-Host 'Przerwano.'; exit 3 }
}

$computer = $env:COMPUTERNAME
$now = Get-Date
$imageTarget = Get-ImageTarget -Params $p -ComputerName $computer -Now $now
$used = Get-UsedBytes -Volumes $all -Selected $vols
Write-Host ''
Write-Host "Komputer:   $computer"
Write-Host "Woluminy:   $($vols -join ', ')  (użyte: $(Format-Size $used))"
Write-Host "Cel:        $($imageTarget.BackupTarget)"
if (-not $Yes) {
    $a = Read-Host 'Rozpocząć kopię? (T/N)'
    if ($a -notmatch '^[TtYy]') { Write-Host 'Przerwano.'; exit 3 }
}

# Wyjście poleceń jest pokazywane na żywo (kopia może trwać godzinami) i zbierane do logu.
$runner = {
    param($Exe, $ArgList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @ArgList 2>&1 | ForEach-Object { $line = "$_"; Write-Host (Hide-Secrets -Text $line); $line }
        return @{ ExitCode = $LASTEXITCODE; Output = @($out) }
    }
    finally { $ErrorActionPreference = $prev }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$volInfo = @($all | Where-Object { $vols -contains $_.Drive })
$result = Invoke-ResurectBackup -Params $p -Target $imageTarget -Facts $facts -Volumes $vols -Runner $runner `
    -Credential $credential -ComputerName $computer -Now $now -OsCaption $os.Caption -OsVersion $os.Version `
    -VolumeInfo $volInfo -SkippedInfo $skipped
$credential = $null

Write-Host ''
foreach ($m in $result.Messages) { Write-Host $m }
Write-Host ''
if ($result.ExitCode -eq 0) { Write-Host "Gotowe. Dokumenty kopii: $($result.DocDir)" -ForegroundColor Green }
else { Write-Host "Kopia NIE powiodła się: $($result.Status)" -ForegroundColor Red }
exit $result.ExitCode
