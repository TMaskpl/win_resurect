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
if (-not (Test-Path -LiteralPath (Join-Path $workDir 'daily.json'))) {
    Write-Host 'Kopia codzienna nie jest zainstalowana na tym komputerze.' -ForegroundColor Yellow
    exit 2
}
$lr = Read-LastRun -Path (Join-Path $workDir 'last-run.json')
Write-Host (Get-DailyStatusText -LastRun $lr -Now (Get-Date))
$mt = Read-LastRun -Path (Join-Path $workDir 'last-maintenance.json')
if ($mt) { Write-Host "Konserwacja tygodniowa: $($mt.status) ($($mt.finished))" }
$stale = Get-DailyStaleness -LastRun $lr -Now (Get-Date)
if ($stale -ne 'fresh' -or ($lr -and $lr.status -eq 'fail')) { exit 1 }
exit 0
