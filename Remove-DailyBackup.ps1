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
if (-not $Yes) {
    Write-Host "Usunę zadania harmonogramu i katalog $workDir (razem z hasłem repozytorium i poświadczeniami). Kopie na nośniku ZOSTANĄ." -ForegroundColor Yellow
    $a = Read-Host 'Czy hasło repozytorium restic jest zapisane w KeePass? Kontynuować? (T/N)'
    if ($a -notmatch '^[TtYy]') { Write-Host 'Przerwano.'; exit 3 }
}
Unregister-DailyTasks
if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
Write-Host 'Usunięto zadania i pliki robocze kopii codziennej.' -ForegroundColor Green
exit 0
