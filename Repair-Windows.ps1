[CmdletBinding()]
param([string]$Root, [string[]]$Modules = @(), [string]$Undo = '', [string]$ImageDate = '', [string]$SkipBackupCheck = '', [switch]$Yes)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
foreach ($m in 'WinResurect.psm1', 'DailyBackup.psm1', 'Repair.psm1') {
    $mp = Join-Path (Join-Path $Root 'src') $m
    try { Import-Module $mp -Force -ErrorAction Stop }
    catch { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $mp))) }
}

if ($Yes) {
    Write-Host 'Naprawa nie obsługuje -Yes: każdy moduł wymaga świadomej zgody technika.' -ForegroundColor Red
    exit 2
}
# -File przekazuje "a,b" jako jeden napis, więc rozdzielamy przecinki
$Modules = @($Modules | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$img = $null
if ($ImageDate) {
    try { $img = [datetime]::ParseExact($ImageDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { Write-Host "Niepoprawna data obrazu (oczekiwano RRRR-MM-DD): $ImageDate" -ForegroundColor Red; exit 2 }
}
$workDir = Get-DailyHome

if ($Undo) {
    if (-not (Test-IsAdmin)) { Write-Host 'Uruchom jako administrator (Start.cmd robi to automatycznie).' -ForegroundColor Red; exit 2 }
    $u = Invoke-RepairUndo -WorkDir $workDir -Module $Undo
    exit $u.ExitCode
}

$sel = Resolve-RepairModules -Names $Modules
if (-not $sel.Valid) { Write-Host $sel.Error -ForegroundColor Red; exit 2 }

Write-Host 'Naprawa i czyszczenie systemu. Każdy krok pokazuje plan i czeka na twoją zgodę.' -ForegroundColor Cyan
$lastRun = Read-LastRun -Path (Join-Path $workDir 'last-run.json')
$facts = Get-RepairFacts
$r = Invoke-RepairRun -WorkDir $workDir -Names $Modules -Facts $facts -LastRun $lastRun -ImageDate $img -SkipReason $SkipBackupCheck
exit $r.ExitCode
