[CmdletBinding()]
param(
    [string]$Root,
    [ValidateSet('usb', 'smb')][string]$Target,
    [string]$Label,
    [string]$Share,
    [string]$User,
    [string]$Folder = 'WinResurectDaily',
    [string]$Time = '12:30',
    [switch]$Yes
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

Write-Host "win_resurect $(Get-ToolVersion) - kopia codzienna" -ForegroundColor Cyan
if (-not $Target) {
    Write-Host '1) Dysk USB   2) Udział SMB'
    $c = Read-Host 'Wybierz cel kopii codziennej (1/2)'
    if ($c -eq '1') { $Target = 'usb' } elseif ($c -eq '2') { $Target = 'smb' } else { Write-Host 'Przerwano.'; exit 3 }
}
if ($Target -eq 'usb' -and -not $Label) { $Label = Read-Host 'Etykieta dysku USB (np. BACKUP)' }
if ($Target -eq 'smb') {
    if (-not $Share) { $Share = Read-Host 'Udział SMB (np. \\nas\share)' }
    if (-not $User) { $User = Read-Host 'Użytkownik udziału' }
}
try { $t = Test-DailyTargetParams -Target $Target -Label $Label -Share $Share -User $User -Folder $Folder }
catch { Write-Host "Błąd: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
if ($Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Write-Host "Błąd: godzina w formacie GG:MM (otrzymano '$Time')." -ForegroundColor Red; exit 2 }
# Uprawnienia sprawdzamy w kodzie (nie przez #Requires, które nie działa poza Windows i psułoby testy dymne).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Uruchom jako administrator (Start.cmd robi to automatycznie).' -ForegroundColor Red; exit 2 }

# 1. restic: specyfikacja i weryfikacja SHA256 PRZED jakąkolwiek zmianą w systemie
$specPath = Join-Path $Root 'restic-version.json'
try { $spec = Get-ResticVersionSpec -Path $specPath } catch { Write-Host "Błąd: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
$workDir = Get-DailyHome
$resticExe = Join-Path $workDir 'restic.exe'
$haveVersion = ''
if (Test-Path -LiteralPath $resticExe) { $haveVersion = ((& $resticExe version 2>&1) -join ' ') }
$tmpZip = $null
if ($haveVersion -notmatch [regex]::Escape($spec.Version)) {
    $tmpZip = Join-Path $env:TEMP "restic-$($spec.Version).zip"
    Write-Host "Pobieram restic $($spec.Version) ..."
    Invoke-WebRequest -UseBasicParsing -Uri $spec.Url -OutFile $tmpZip
    if (-not (Test-FileSha256 -Path $tmpZip -Expected $spec.Sha256)) {
        Remove-Item -LiteralPath $tmpZip -Force
        Write-Host 'Błąd: suma SHA256 pobranego restic nie zgadza się z restic-version.json. Przerwano, nic nie zainstalowano.' -ForegroundColor Red
        exit 2
    }
}

# 2. hasło SMB
$smbPlain = ''
if ($t.Type -eq 'smb') {
    if ($env:WINRES_PASSWORD) { $sec = ConvertTo-SecureString $env:WINRES_PASSWORD -AsPlainText -Force; Remove-Item Env:WINRES_PASSWORD -ErrorAction SilentlyContinue }
    else { $sec = Read-Host "Hasło użytkownika $($t.User)" -AsSecureString }
    $smbPlain = (New-Object System.Management.Automation.PSCredential($t.User, $sec)).GetNetworkCredential().Password
}

# 3. katalog roboczy, pliki
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Set-RestrictedAcl -Path $workDir
New-Item -ItemType Directory -Force -Path (Join-Path $workDir 'src') | Out-Null
foreach ($f in 'src\WinResurect.psm1', 'src\DailyBackup.psm1', 'Run-DailyBackup.ps1', 'Get-DailyStatus.ps1', 'Restore-DailyBackup.ps1', 'Remove-DailyBackup.ps1', 'restic-version.json') {
    Copy-Item -LiteralPath (Join-Path $Root $f) -Destination (Join-Path $workDir $f) -Force
}
if ($tmpZip) {
    $x = Join-Path $env:TEMP "restic-$($spec.Version)"
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $x -Force
    Copy-Item -LiteralPath (Get-ChildItem $x -Filter 'restic_*.exe' | Select-Object -First 1).FullName -Destination $resticExe -Force
    Remove-Item -LiteralPath $tmpZip, $x -Recurse -Force
}

# 4. daily.json: nowy z szablonu albo aktualizacja celu i godziny
$cfgPath = Join-Path $workDir 'daily.json'
if (Test-Path -LiteralPath $cfgPath) {
    $json = Update-DailyConfigJson -Json (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) -Type $t.Type -Label $t.Label -Share $t.Share -User $t.User -Folder $t.Folder -Time $Time
}
else {
    $defaults = @((Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Desktop'))
    $json = New-DailyConfigJson -Type $t.Type -Label $t.Label -Share $t.Share -User $t.User -Folder $t.Folder -Time $Time -Folders $defaults
}
Set-Content -LiteralPath $cfgPath -Value $json -Encoding UTF8

# 5. hasło repozytorium (raz, do KeePass)
$passFile = Join-Path $workDir 'repo.pass'
if (-not (Test-Path -LiteralPath $passFile)) {
    $pw = New-RandomPassword -Length 32
    [System.IO.File]::WriteAllText($passFile, $pw)
    Set-RestrictedAcl -Path $passFile
    Write-Host ''
    Write-Host 'HASŁO REPOZYTORIUM (zapisz TERAZ w KeePass; bez niego kopia jest nie do odczytania):' -ForegroundColor Yellow
    Write-Host $pw
    Write-Host ''
    Read-Host 'Naciśnij Enter po zapisaniu hasła' | Out-Null
    $pw = $null
}

# 6. hasło SMB zaszyfrowane DPAPI przez SYSTEM
if ($t.Type -eq 'smb') {
    $tmpPlain = Join-Path $workDir 'smb.tmp'
    [System.IO.File]::WriteAllText($tmpPlain, $smbPlain)
    Set-RestrictedAcl -Path $tmpPlain
    $smbPlain = $null
    $credScript = @"
`$p = (Get-Content -LiteralPath '$tmpPlain' -Raw).Trim()
`$sec = ConvertTo-SecureString `$p -AsPlainText -Force
Set-Content -LiteralPath '$workDir\smb.cred' -Value @('$($t.User)', (ConvertFrom-SecureString `$sec)) -Encoding ASCII
Remove-Item -LiteralPath '$tmpPlain' -Force
"@
    $rc = Invoke-AsSystem -Name 'WinResurect-SetCred' -ScriptText $credScript -WorkDir $workDir -TimeoutSec 60
    Remove-Item -LiteralPath $tmpPlain -Force -ErrorAction SilentlyContinue
    if ($rc -ne 0) { Write-Host "Błąd: zapis poświadczeń SMB jako SYSTEM nie powiódł się (kod $rc), zobacz $workDir\WinResurect-SetCred.log" -ForegroundColor Red; exit 1 }
}

# 7. lista folderów: technik edytuje daily.json
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host "Otwieram $cfgPath - wpisz foldery do kopiowania, zapisz plik i zamknij Notatnik."
    if (-not $Yes) { Start-Process notepad.exe -ArgumentList "`"$cfgPath`"" -Wait }
    try { $cfg = Read-DailyConfig -Path $cfgPath; break }
    catch { Write-Host "Błąd w pliku: $($_.Exception.Message)" -ForegroundColor Red; if ($Yes) { exit 2 }; if ($attempt -eq 3) { exit 2 } }
}

# 8. inicjalizacja repozytorium jako SYSTEM, potem zadania harmonogramu i pierwsza kopia
$rc = Invoke-AsSystem -Name 'WinResurect-Init' -ScriptText "& '$workDir\Run-DailyBackup.ps1' -Mode init; exit `$LASTEXITCODE" -WorkDir $workDir -TimeoutSec 300
if ($rc -ne 0) { Write-Host "Błąd: inicjalizacja repozytorium nie powiodła się (kod $rc). Zobacz $workDir\last-init.json i $workDir\daily.log" -ForegroundColor Red; exit 1 }
Register-DailyTasks -Specs (Get-DailyTaskSpecs -InstallDir $workDir -Time $cfg.Time)
Write-Host 'Zadania harmonogramu zarejestrowane. Uruchamiam pierwszą kopię ...' -ForegroundColor Green
Start-ScheduledTask -TaskName 'WinResurect-Daily'
$logFile = Join-Path $workDir 'daily.log'
$shown = 0
Start-Sleep -Seconds 3
do {
    Start-Sleep -Seconds 5
    if (Test-Path -LiteralPath $logFile) {
        $all = @(Get-Content -LiteralPath $logFile)
        if ($all.Count -gt $shown) { $all[$shown..($all.Count - 1)] | ForEach-Object { Write-Host $_ }; $shown = $all.Count }
    }
    $state = (Get-ScheduledTask -TaskName 'WinResurect-Daily').State
} while ($state -eq 'Running')
$lr = Read-LastRun -Path (Join-Path $workDir 'last-run.json')
Write-Host ''
Write-Host (Get-DailyStatusText -LastRun $lr -Now (Get-Date))
Write-Host "Lista folderów: $cfgPath. Status: Start.cmd -Action status. Odtwarzanie: Start.cmd -Action restore." -ForegroundColor Green
if ($lr -and $lr.status -eq 'fail') { exit 1 }
exit 0
