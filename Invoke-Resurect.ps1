[CmdletBinding()]
param(
    [ValidateSet('usb', 'smb')][string]$Target,
    [string]$Drive,
    [string]$Share,
    [string]$User,
    [string]$Folder = 'WinResurect',
    [switch]$Yes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Join-Path $PSScriptRoot 'src') 'WinResurect.psm1'
try { Import-Module $modulePath -Force -ErrorAction Stop }
catch { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $modulePath))) }

function Read-Plain([string]$Prompt) {
    $sec = Read-Host $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

Write-Host "win_resurect $script:ToolVersion - kopia całego systemu przed naprawą" -ForegroundColor Cyan

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

$password = ''
if ($Target -eq 'smb') {
    if ($env:WINRES_PASSWORD) { $password = $env:WINRES_PASSWORD; Remove-Item Env:WINRES_PASSWORD -ErrorAction SilentlyContinue }
    else { $password = Read-Plain "Hasło użytkownika $User" }
}

try { $p = Test-ResurectParams -Target $Target -Drive $Drive -Share $Share -User $User -Folder $Folder }
catch { Write-Host "Błąd: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }

$all = @(Get-LocalVolumes)
$targetDrive = if ($p.Target -eq 'usb') { $p.Drive } else { '' }
$vols = @(Select-BackupVolumes -Volumes $all -TargetDrive $targetDrive)
$facts = Get-ResurectFacts -Params $p -AllVolumes $all -Selected $vols

if ($facts.BitLockerProtected) {
    Write-Host 'Wykryto BitLocker. Bez klucza odzyskiwania odtworzony dysk może być niedostępny.' -ForegroundColor Yellow
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

$runner = {
    param($Exe, $ArgList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
        return @{ ExitCode = $LASTEXITCODE; Output = @($out) }
    }
    finally { $ErrorActionPreference = $prev }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$volInfo = @($all | Where-Object { $vols -contains $_.Drive })
$result = Invoke-ResurectBackup -Params $p -Target $imageTarget -Facts $facts -Volumes $vols -Runner $runner `
    -Password $password -ComputerName $computer -Now $now -OsCaption $os.Caption -OsVersion $os.Version -VolumeInfo $volInfo
$password = $null

Write-Host ''
foreach ($m in $result.Messages) { Write-Host $m }
Write-Host ''
if ($result.ExitCode -eq 0) { Write-Host "Gotowe. Dokumenty kopii: $($result.DocDir)" -ForegroundColor Green }
else { Write-Host "Kopia NIE powiodła się: $($result.Status)" -ForegroundColor Red }
exit $result.ExitCode
