[CmdletBinding()]
param([string]$Root)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
foreach ($m in 'WinResurect.psm1', 'DailyBackup.psm1', 'Repair.psm1') {
    $mp = Join-Path (Join-Path $Root 'src') $m
    try { Import-Module $mp -Force -ErrorAction Stop }
    catch { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $mp))) }
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Uwaga: bez uprawnień administratora część danych (SMART, DISM) będzie niedostępna. Użyj Start.cmd.' -ForegroundColor Yellow
}
$now = Get-Date
Write-Host 'Zbieram dane o systemie (to potrwa około minuty, bez żadnych zmian)...'
$audit = Invoke-RepairAudit -Now $now
$dir = New-RepairRunDir -WorkDir (Get-DailyHome) -Now $now
Save-AuditFile -Audit $audit -Dir $dir -Name 'audit' | Out-Null
$report = Format-AuditReport -Audit $audit
Set-Content -LiteralPath (Join-Path $dir 'raport.txt') -Value $report -Encoding UTF8
Write-Host ''
Write-Host $report
Write-Host ''
Write-Host "Zapisano: $dir"
exit 0
