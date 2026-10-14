[CmdletBinding()]
param(
    [string]$Root,
    [ValidateSet('usb', 'smb')][string]$Target,
    [string]$Label,
    [string]$Share,
    [string]$User,
    [string]$Folder,
    [string]$Time
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

# Przy aktualizacji godzina i folder repozytorium zostają, jeśli nie podano nowych.
$workDir = Get-DailyHome
$cfgPath = '{0}\daily.json' -f $workDir.TrimEnd('\')
$existing = $null
if (Test-Path -LiteralPath $cfgPath) {
    try { $existing = ConvertTo-DailyConfig -Raw (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) } catch { $existing = $null }
}
if (-not $Folder) { $Folder = if ($existing -and $existing.Target.Folder) { $existing.Target.Folder } else { 'WinResurectDaily' } }
if (-not $Time) { $Time = if ($existing -and $existing.Time) { $existing.Time } else { '12:30' } }

try { $t = Test-DailyTargetParams -Target $Target -Label $Label -Share $Share -User $User -Folder $Folder }
catch { Write-Host "Błąd: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
if ($Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Write-Host "Błąd: godzina w formacie GG:MM (otrzymano '$Time')." -ForegroundColor Red; exit 2 }

# hasło SMB (potrzebne już do sprawdzenia połączenia przed jakąkolwiek zmianą)
$smbPlain = ''
if ($t.Type -eq 'smb') {
    if ($env:WINRES_PASSWORD) { $sec = ConvertTo-SecureString $env:WINRES_PASSWORD -AsPlainText -Force; Remove-Item Env:WINRES_PASSWORD -ErrorAction SilentlyContinue }
    else { $sec = Read-Host "Hasło użytkownika $($t.User)" -AsSecureString }
    $smbPlain = (New-Object System.Management.Automation.PSCredential($t.User, $sec)).GetNetworkCredential().Password
}

# 0. Kontrole wstępne: nic nie jest zmieniane, dopóki wszystkie nie przejdą
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$is64 = [Environment]::Is64BitOperatingSystem
$targetOk = $true; $targetReason = ''
if ($isAdmin) {
    if ($t.Type -eq 'usb') {
        $res = Resolve-DailyTarget -Config ([pscustomobject]@{ Target = $t }) -Volumes @(Get-LocalVolumes) -ComputerName $env:COMPUTERNAME
        if (-not $res.Ok) { $targetOk = $false; $targetReason = $res.Reason }
    }
    else {
        $root2 = Get-ShareRoot -Share $t.Share
        $cc = Connect-NetworkShare -Share $root2 -User $t.User -Password $smbPlain
        if ($cc.ExitCode -ne 0) { $targetOk = $false; $targetReason = "nie można połączyć się z udziałem (kod $($cc.ExitCode)): $(@($cc.Output) -join ' ')" }
        else {
            if (-not (Test-Path -LiteralPath $root2)) { $targetOk = $false; $targetReason = 'udział nie jest dostępny po połączeniu' }
            [void](Disconnect-NetworkShare -Share $root2)
        }
    }
}
$trusted = $true
if (Test-Path -LiteralPath $workDir) {
    try { $trusted = Test-TrustedOwnerSid -Sid ((Get-Acl -LiteralPath $workDir).GetOwner([System.Security.Principal.SecurityIdentifier]).Value) }
    catch { $trusted = $false }
}
$errs = @(Get-InstallPreflightErrors -IsAdmin $isAdmin -Is64Bit $is64 -TargetOk $targetOk -TargetReason $targetReason -WorkDirTrusted $trusted -WorkDir $workDir)
if ($errs.Count -gt 0) { foreach ($e in $errs) { Write-Host "Błąd: $e" -ForegroundColor Red }; exit 2 }

# 1. restic: pobranie do chronionego katalogu tymczasowego, weryfikacja SHA256, rozpakowanie; dopiero potem zmiany w systemie
$specPath = Join-Path $Root 'restic-version.json'
try { $spec = Get-ResticVersionSpec -Path $specPath } catch { Write-Host "Błąd: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
$ProgressPreference = 'SilentlyContinue'
$secureTmp = Join-Path $env:TEMP ('winres-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $secureTmp | Out-Null
Set-RestrictedAcl -Path $secureTmp
try {
    $zip = Join-Path $secureTmp 'restic.zip'
    Write-Host "Pobieram restic $($spec.Version) ..."
    Invoke-WebRequest -UseBasicParsing -Uri $spec.Url -OutFile $zip
    if (-not (Test-FileSha256 -Path $zip -Expected $spec.Sha256)) {
        Write-Host 'Błąd: suma SHA256 pobranego restic nie zgadza się z restic-version.json. Przerwano, nic nie zainstalowano.' -ForegroundColor Red
        exit 2
    }
    $unpacked = Join-Path $secureTmp 'x'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
    $exeSrc = Join-Path $unpacked (Get-ResticExeName -Version $spec.Version)
    if (-not (Test-Path -LiteralPath $exeSrc)) {
        Write-Host "Błąd: w pobranym archiwum nie ma pliku $(Get-ResticExeName -Version $spec.Version). Przerwano." -ForegroundColor Red
        exit 2
    }

    # 2. katalog roboczy i pliki (restic.exe zawsze z zweryfikowanego archiwum, nigdy z istniejącego pliku)
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Set-RestrictedAcl -Path $workDir
    New-Item -ItemType Directory -Force -Path (Join-Path $workDir 'src') | Out-Null
    foreach ($f in 'src\WinResurect.psm1', 'src\DailyBackup.psm1', 'Run-DailyBackup.ps1', 'Get-DailyStatus.ps1', 'Restore-DailyBackup.ps1', 'Remove-DailyBackup.ps1', 'restic-version.json') {
        Copy-Item -LiteralPath (Join-Path $Root $f) -Destination (Join-Path $workDir $f) -Force
    }
    try { Copy-Item -LiteralPath $exeSrc -Destination (Join-Path $workDir 'restic.exe') -Force }
    catch { Write-Host "Błąd: nie można zapisać restic.exe (czy trwa właśnie kopia?): $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}
finally { Remove-Item -LiteralPath $secureTmp -Recurse -Force -ErrorAction SilentlyContinue }

# 3. daily.json: nowy z szablonu albo aktualizacja celu (godzina i folder zostają, jeśli nie podano)
if (Test-Path -LiteralPath $cfgPath) {
    $json = Update-DailyConfigJson -Json (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) -Type $t.Type -Label $t.Label -Share $t.Share -User $t.User -Folder $Folder -Time $Time
}
else {
    $defaults = @((Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Desktop'))
    $json = New-DailyConfigJson -Type $t.Type -Label $t.Label -Share $t.Share -User $t.User -Folder $Folder -Time $Time -Folders $defaults
}
Set-Content -LiteralPath $cfgPath -Value $json -Encoding UTF8

# 4. hasło repozytorium (raz, do KeePass)
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

# 5. hasło SMB zaszyfrowane DPAPI przez SYSTEM
if ($t.Type -eq 'smb') {
    $tmpPlain = Join-Path $workDir 'smb.tmp'
    [System.IO.File]::WriteAllText($tmpPlain, $smbPlain)
    Set-RestrictedAcl -Path $tmpPlain
    $smbPlain = $null
    $credScript = Get-SetCredScript -TmpPath $tmpPlain -CredPath (Join-Path $workDir 'smb.cred') -User $t.User
    $rc = Invoke-AsSystem -Name 'WinResurect-SetCred' -ScriptText $credScript -WorkDir $workDir -TimeoutSec 60
    Remove-Item -LiteralPath $tmpPlain -Force -ErrorAction SilentlyContinue
    if ($rc -ne 0) { Write-Host "Błąd: zapis poświadczeń SMB jako SYSTEM nie powiódł się (kod $rc), zobacz $workDir\WinResurect-SetCred.log" -ForegroundColor Red; exit 1 }
}

# 6. lista folderów: technik edytuje daily.json
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host "Otwieram $cfgPath - wpisz foldery do kopiowania, zapisz plik i zamknij Notatnik."
    Start-Process notepad.exe -ArgumentList "`"$cfgPath`"" -Wait
    try { $cfg = Read-DailyConfig -Path $cfgPath; break }
    catch { Write-Host "Błąd w pliku: $($_.Exception.Message)" -ForegroundColor Red; if ($attempt -eq 3) { exit 2 } }
}

# 7. inicjalizacja repozytorium jako SYSTEM, potem zadania harmonogramu i pierwsza kopia
$initScript = '& {0} -Mode init; exit $LASTEXITCODE' -f (ConvertTo-SingleQuoted "$workDir\Run-DailyBackup.ps1")
$rc = Invoke-AsSystem -Name 'WinResurect-Init' -ScriptText $initScript -WorkDir $workDir -TimeoutSec 300
if ($rc -ne 0) { Write-Host "Błąd: inicjalizacja repozytorium nie powiodła się (kod $rc). Zobacz $workDir\last-init.json i $workDir\daily.log" -ForegroundColor Red; exit 1 }
Register-DailyTasks -Specs (Get-DailyTaskSpecs -InstallDir $workDir -Time $cfg.Time)
Write-Host 'Zadania harmonogramu zarejestrowane. Uruchamiam pierwszą kopię (przy dużych danych trwa to godzinami) ...' -ForegroundColor Green
Start-ScheduledTask -TaskName 'WinResurect-Daily'
$logFile = Join-Path $workDir 'daily.log'
$shown = 0
$begin = Get-Date
$tick = Get-Date
$deadline = $begin.AddHours(6.5)
Start-Sleep -Seconds 3
do {
    Start-Sleep -Seconds 5
    if (Test-Path -LiteralPath $logFile) {
        $all = @(Get-Content -LiteralPath $logFile)
        if ($all.Count -gt $shown) { $all[$shown..($all.Count - 1)] | ForEach-Object { Write-Host $_ }; $shown = $all.Count }
    }
    if (((Get-Date) - $tick).TotalSeconds -ge 60) {
        Write-Host ('  ... kopia trwa już {0} min' -f [int]((Get-Date) - $begin).TotalMinutes)
        $tick = Get-Date
    }
    $state = (Get-ScheduledTask -TaskName 'WinResurect-Daily').State
} while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
$lr = Read-LastRun -Path (Join-Path $workDir 'last-run.json')
Write-Host ''
Write-Host (Get-DailyStatusText -LastRun $lr -Now (Get-Date))
Write-Host "Lista folderów: $cfgPath. Status: Start.cmd -Action status. Odtwarzanie: Start.cmd -Action restore." -ForegroundColor Green
if ($lr -and (Get-ConfigValue $lr 'status' '') -eq 'fail') { exit 1 }
exit 0
