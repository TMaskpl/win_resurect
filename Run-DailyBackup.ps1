[CmdletBinding()]
param(
    [string]$Root,
    [ValidateSet('backup', 'maintenance', 'init')][string]$Mode = 'backup'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
foreach ($m in 'WinResurect.psm1', 'DailyBackup.psm1') {
    $mp = Join-Path (Join-Path $Root 'src') $m
    try { Import-Module $mp -Force -ErrorAction Stop }
    catch { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $mp))) }
}
$workDir = Get-DailyHome
$resticPath = Join-Path $workDir 'restic.exe'
try { $cfg = Read-DailyConfig -Path (Join-Path $workDir 'daily.json') }
catch {
    $now = Get-Date
    $lr = New-LastRun -Status fail -Started $now -Finished $now -Note $_.Exception.Message `
        -Previous (Read-LastRun -Path (Join-Path $workDir 'last-run.json'))
    Save-LastRun -Path (Join-Path $workDir 'last-run.json') -LastRun $lr
    Write-DailyLog -Path (Join-Path $workDir 'daily.log') -Lines @("$($now.ToString('yyyy-MM-dd HH:mm:ss')) Błąd konfiguracji: $(Format-Note -Text $_.Exception.Message)")
    exit 1
}
$env:GOMAXPROCS = '2'
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'

$runner = {
    param($Exe, $ArgList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $resticPath @ArgList 2>&1 | ForEach-Object { "$_" }
        return @{ ExitCode = $LASTEXITCODE; Output = @($out) }
    }
    finally { $ErrorActionPreference = $prev }
}
$readCred = {
    $f = Join-Path $workDir 'smb.cred'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $lines = @(Get-Content -LiteralPath $f)
    if ($lines.Count -lt 2) { return $null }
    return (New-Object System.Management.Automation.PSCredential($lines[0], (ConvertTo-SecureString $lines[1])))
}
$version = ''
try { $version = ((& $resticPath version 2>&1) -join ' ') -replace '^restic\s+([\d.]+).*$', '$1' } catch { }

$result = Invoke-DailyJob -Mode $Mode -Config $cfg -Volumes @(Get-LocalVolumes) -Runner $runner -WorkDir $workDir `
    -ReadSmbCredential $readCred -ResticVersion $version
exit $result.ExitCode
