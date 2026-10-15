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
Write-Host 'Zbieram dane o systemie (to potrwa kilka minut, bez żadnych zmian)...'
$audit = Invoke-RepairAudit -Now $now
$report = Format-AuditReport -Audit $audit
Write-Host ''
Write-Host $report
Write-Host ''

# Raport jest już na ekranie; zapis nie może go przekreślić (zwykły użytkownik nie zapisze w ProgramData).
$dir = $null
try { $dir = New-RepairRunDir -WorkDir (Get-DailyHome) -Now $now }
catch {
    $fallback = Join-Path ([System.IO.Path]::GetTempPath()) ('WinResurect-audit-' + $now.ToString('yyyyMMdd-HHmmss'))
    try {
        New-Item -ItemType Directory -Force -Path $fallback -ErrorAction Stop | Out-Null
        $dir = $fallback
        Write-Host "Brak dostępu do katalogu roboczego (uruchom jako administrator). Zapis awaryjny: $dir" -ForegroundColor Yellow
    }
    catch { Write-Host 'Nie udało się zapisać raportu na dysku; powyższy wynik jest tylko na ekranie.' -ForegroundColor Yellow }
}
if ($dir) {
    try {
        Save-AuditFile -Audit $audit -Dir $dir -Name 'audit' | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'raport.txt') -Value $report -Encoding UTF8 -ErrorAction Stop
        Write-Host "Zapisano: $dir"
    }
    catch { Write-Host "Nie udało się zapisać raportu: $($_.Exception.Message)" -ForegroundColor Yellow }
}
exit 0
