[CmdletBinding()]
param([string]$Root, [switch]$Yes)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
foreach ($m in 'WinResurect.psm1', 'DailyBackup.psm1') {
    $mp = Join-Path (Join-Path $Root 'src') $m
    try { Import-Module $mp -Force -ErrorAction Stop }
    catch { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $mp))) }
}

$workDir = Get-DailyHome
$cfgPath = Join-Path $workDir 'daily.json'
if (-not (Test-Path -LiteralPath $cfgPath)) { Write-Host 'Kopia codzienna nie jest zainstalowana.' -ForegroundColor Yellow; exit 2 }
try { $cfg = Read-DailyConfig -Path $cfgPath } catch { Write-Host "Błąd: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
$computer = $env:COMPUTERNAME
$vols = @(Get-LocalVolumes)
$target = Resolve-DailyTarget -Config $cfg -Volumes $vols -ComputerName $computer
if (-not $target.Ok) { Write-Host "Błąd: $($target.Reason)" -ForegroundColor Red; exit 2 }

$connected = $false
try {
    if ($cfg.Target.Type -eq 'smb') {
        $sec = Read-Host "Hasło użytkownika $($cfg.Target.User) do udziału" -AsSecureString
        $plain = (New-Object System.Management.Automation.PSCredential($cfg.Target.User, $sec)).GetNetworkCredential().Password
        $c = Connect-NetworkShare -Share $target.ShareRoot -User $cfg.Target.User -Password $plain
        $plain = $null
        if ($c.ExitCode -ne 0) { Write-Host "Błąd: nie można połączyć się z udziałem (kod $($c.ExitCode))." -ForegroundColor Red; exit 2 }
        $connected = $true
    }
    $env:RESTIC_REPOSITORY = $target.Repository
    $env:RESTIC_PASSWORD_FILE = Join-Path $workDir 'repo.pass'
    $restic = Join-Path $workDir 'restic.exe'
    $json = & $restic snapshots --json --host $computer 2>$null
    $snaps = @(ConvertFrom-ResticSnapshots -Json ($json -join "`n") | Sort-Object Time -Descending)
    if ($snaps.Count -eq 0) { Write-Host 'Brak migawek w repozytorium.' -ForegroundColor Yellow; exit 2 }
    for ($i = 0; $i -lt $snaps.Count; $i++) { Write-Host ('{0,2}) {1}  {2}  {3}' -f ($i + 1), $snaps[$i].ShortId, $snaps[$i].Time.ToString('yyyy-MM-dd HH:mm'), ($snaps[$i].Paths -join ', ')) }
    $n = Read-Host 'Numer migawki (Enter = najnowsza)'
    $snap = if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $snaps.Count) { $snaps[[int]$n - 1] } else { $snaps[0] }
    $inc = Read-Host 'Folder lub plik do przywrócenia (pełna ścieżka z migawki; Enter = wszystko)'
    $base = [Environment]::GetFolderPath('Desktop'); if (-not $base) { $base = $env:USERPROFILE }
    $dest = New-RestoreTarget -Base $base -Now (Get-Date)
    if (-not (Test-RestoreTargetSafe -Target $dest -Folders @($cfg.Folders))) { Write-Host "Błąd: cel przywracania $dest koliduje z kopiowanymi folderami." -ForegroundColor Red; exit 2 }
    $inList = @(); if ($inc) { $inList = @($inc) }
    Write-Host "Przywracam migawkę $($snap.ShortId) do $dest ..."
    & $restic @(Get-RestoreArgs -SnapshotId $snap.Id -Target $dest -Include $inList)
    if ($LASTEXITCODE -ne 0) { Write-Host "Błąd: restic zakończył się kodem $LASTEXITCODE." -ForegroundColor Red; exit 1 }
    Write-Host "Gotowe. Pliki są w $dest (z pełną strukturą katalogów z migawki). Oryginały nie zostały zmienione." -ForegroundColor Green
}
finally {
    if ($connected) { [void](Disconnect-NetworkShare -Share $target.ShareRoot) }
    Remove-Item Env:RESTIC_REPOSITORY, Env:RESTIC_PASSWORD_FILE -ErrorAction SilentlyContinue
}
exit 0
