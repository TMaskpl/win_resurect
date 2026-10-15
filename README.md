# win_resurect

**EN:** A small Windows tool that makes a full system image (via the built-in `wbadmin`) to a USB disk or an SMB share *before* you start repairing a PC, so you can always roll back. Run `Start.cmd`, pick the target, done. Public, MIT, no telemetry.

Narzędzie robi **pełną kopię systemu (obraz) przed naprawą komputera**, na dysk USB albo udział SMB, używając wbudowanego w Windows `wbadmin`. Po nieudanej naprawie możesz wrócić do stanu sprzed ingerencji, a pojedyncze pliki odzyskać bez przywracania całości.

## Status

Wersja **przedpremierowa (0.1.0)**. Kopia na dysk **USB** została sprawdzona na Windows 11 Pro (obraz C:, D:, G: i partycji EFI/odzyskiwania, kod wyjścia 0, weryfikacja przeszła). Kopia na **udział SMB** jest zaimplementowana i przetestowana jednostkowo, ale nie przeszła jeszcze testu na prawdziwym udziale; do tego czasu traktuj ją jako eksperymentalną. Odtwarzanie z środowiska odzyskiwania (WinRE) czeka na test. Dodatkowo: **kopia codzienna wybranych folderów (restic)** jest zaimplementowana i przetestowana jednostkowo, ale nie przeszła jeszcze testów na prawdziwym Windows. Nie ma jeszcze oficjalnego wydania z sumą SHA256.

## Wymagania

- Windows 10 lub 11, PowerShell 5.1 (jest w systemie), uprawnienia administratora.
- Cel: dysk USB w **NTFS** (osobny fizyczny dysk) albo udział SMB z prawem zapisu.
- Wolne miejsce na celu co najmniej o 10% większe niż zajęte miejsce na kopiowanych dyskach.
- Laptop podłączony do zasilania. Odłącz zbędne dyski zewnętrzne (każdy stały dysk NTFS trafi do kopii).

## Pobranie i weryfikacja

**Do czasu pierwszego wydania:** pobierz ZIP przyciskiem **Code → Download ZIP** na stronie repozytorium, rozpakuj go na dysk lokalny (np. `C:\win_resurect`, nie na dysk docelowy kopii) i sprawdź, że przejrzany przez ciebie kod pochodzi z oczekiwanego commita.

**Po pierwszym wydaniu** (strona **Releases**):

1. Pobierz plik `win_resurect-<wersja>.zip` oraz `SHA256SUMS.txt`.
2. Sprawdź sumę w PowerShellu (wynik musi być taki sam jak w `SHA256SUMS.txt`):

```powershell
Get-FileHash .\win_resurect-<wersja>.zip -Algorithm SHA256
```

3. Rozpakuj ZIP (np. do `C:\win_resurect`). Nie uruchamiaj narzędzia, jeśli suma się nie zgadza.

## Uruchomienie

Uruchom `Start.cmd` (zgoda UAC pojawi się sama, jeśli nie masz uprawnień administratora). Bez parametrów pokaże menu. Przykłady:

```bat
Start.cmd -Target usb -Drive E:
Start.cmd -Target smb -Share \\nas\share -User uzytkownik
```

| Parametr | Znaczenie |
|---|---|
| `-Target usb` lub `-Target smb` | cel kopii |
| `-Drive E:` | litera dysku USB (dla `usb`) |
| `-Share \\serwer\udział`, `-User` | udział SMB i użytkownik (dla `smb`) |
| `-Folder nazwa` | podfolder na nośniku (domyślnie `WinResurect`; litery, cyfry, `.`, `-`, `_`) |
| `-Yes` | pomija pytania o potwierdzenie (nie dotyczy BitLockera) |

**Hasło SMB** podajesz po zachęcie (nie jest widoczne). To zalecany sposób: hasło nie trafia do historii poleceń, do wiersza poleceń żadnego procesu ani do logów. Hasło jest przekazywane do Windows jako `SecureString` i przez interfejs sieciowy systemu (`WNetAddConnection2`), a nie przez `net use`.

Zmienna `WINRES_PASSWORD` jest tylko awaryjną opcją dla uruchomień bez nadzoru. **Nie ustawiaj jej w PowerShellu** (zapisze hasło w historii poleceń PSReadLine). Jeśli musisz, ustaw ją w `cmd` (`set WINRES_PASSWORD=...`) w oknie uruchomionym już jako administrator, bo po podniesieniu uprawnień zmienna może nie zostać przekazana. Nigdy nie wpisuj hasła w parametrach ani w plikach.

Uruchamiaj narzędzie z dysku lokalnego (np. `C:\win_resurect`). Po podniesieniu uprawnień (UAC) dyski sieciowe zmapowane w sesji użytkownika znikają.

## Kopia codzienna wybranych folderów (restic)

Druga funkcja narzędzia: zadanie w Harmonogramie Windows, które **codziennie, różnicowo** kopiuje foldery z pliku `daily.json` na dysk USB (rozpoznawany po etykiecie) albo udział SMB. Używa [restic](https://restic.net) (szyfrowanie, deduplikacja, migawki VSS dla otwartych plików).

```bat
Start.cmd -Action install-daily -Target usb -Label BACKUP [-Time 12:30] [-Folder WinResurectDaily]
Start.cmd -Action install-daily -Target smb -Share \\nas\share -User uzytkownik
Start.cmd -Action status
Start.cmd -Action restore
Start.cmd -Action remove-daily
```

Instalacja pobiera restic z oficjalnego wydania na GitHubie, w wersji i z sumą SHA256 zapisaną w `restic-version.json` (niezgodna suma przerywa instalację), tworzy `C:\ProgramData\WinResurect\`, pokazuje **raz** hasło repozytorium (zapisz je w KeePass; bez niego kopia jest nie do odczytania), otwiera `daily.json` do wpisania folderów i rejestruje zadania. Szczegóły: [`docs/KOPIA-CODZIENNA.md`](docs/KOPIA-CODZIENNA.md).

## Naprawa i czyszczenie systemu

> Wersja przedpremierowa: zaimplementowana i przetestowana jednostkowo, jeszcze nie na prawdziwym Windows.

Dwie akcje dla technika, uruchamiane z Start.cmd jako administrator (szczegóły: [docs/NAPRAWA.md](docs/NAPRAWA.md), checklista wizyty: [docs/WIZYTA.md](docs/WIZYTA.md)):

```bat
Start.cmd -Action audit
Start.cmd -Action repair -ImageDate 2026-10-15
Start.cmd -Action repair -Modules cleanup,startup
Start.cmd -Action repair -Undo startup
```

- `audit` tylko czyta: dysk (SMART), wolne miejsce, czas startu, autostart, integralność systemu, aktualizacje, pamięć i restarty awaryjne. Zapisuje raport w `C:\ProgramData\WinResurect\repair\<data>\`.
- `repair` najpierw sprawdza, czy jest świeża kopia (codzienna do 48 h albo obraz podany przez `-ImageDate`, do 30 dni) i tworzy punkt przywracania. Potem uruchamia moduły `system-repair`, `windows-update`, `cleanup`, `startup`, każdy po pokazaniu planu i za twoją zgodą (`-Yes` nie istnieje). Na końcu pokazuje różnicę przed i po.
- Zmiany w `startup` i `windows-update` można cofnąć (`-Undo`). Czyszczenie plików jest nieodwracalne, dlatego wymaga kopii.

## Co robi narzędzie (kopia całego systemu)

1. Sprawdza uprawnienia, cel, miejsce, BitLocker i zasilanie. Przy błędzie niczego nie zapisuje.
2. Łączy się z udziałem (SMB) na czas pracy.
3. Eksportuje sterowniki (`pnputil`).
4. Tworzy obraz wszystkich lokalnych dysków NTFS (`wbadmin ... -allCritical`).
5. Weryfikuje kopię (lista wersji i obecność pliku obrazu).
6. Zapisuje na nośniku folder `WinResurect\<komputer>_<data>` z plikami `manifest.txt`, `log.txt`, `PRZYWRACANIE.txt` i `drivers\`.
7. Odłącza udział i usuwa referencję do hasła (hasło było tylko w pamięci procesu).

Kody wyjścia: `0` sukces, `1` błąd kopii, `2` nie spełniono warunków przed startem, `3` przerwanie.

## BitLocker

Jeśli dysk jest szyfrowany, narzędzie pyta, czy **klucz odzyskiwania BitLocker jest zapisany poza komputerem i poza tą kopią**. Bez klucza odtworzony system może być niedostępny. Narzędzie nigdy nie odczytuje ani nie zapisuje klucza.

## Odtwarzanie

Pełna instrukcja jest w [`docs/PRZYWRACANIE.md`](docs/PRZYWRACANIE.md) i w pliku `PRZYWRACANIE.txt` przy każdej kopii. W skrócie:

- **Cały komputer** (nadpisze dysk): Ustawienia → System → Odzyskiwanie → Uruchamianie zaawansowane → Rozwiązywanie problemów → Opcje zaawansowane → Więcej opcji odzyskiwania → **Odzyskiwanie obrazu systemu**.
- **Pojedyncze pliki:** zamontuj plik `.vhdx` tylko do odczytu (`Mount-DiskImage -ImagePath "<ścieżka>" -Access ReadOnly`), skopiuj pliki, odmontuj (`Dismount-DiskImage`).

## Rozwiązywanie problemów

| Objaw | Co zrobić |
|---|---|
| „Running scripts is disabled” | Uruchom `Start.cmd` (ma `-ExecutionPolicy Bypass`). Jeśli politykę narzuca GPO i `Start.cmd` nadal się nie uruchamia, otwórz wiersz poleceń jako administrator, przejdź do katalogu narzędzia (`cd /d C:\win_resurect`) i uruchom: `powershell -NoProfile -Command "& ([scriptblock]::Create((Get-Content -Raw .\Invoke-Resurect.ps1))) -Target usb -Drive E:"` (parametry jak w `Start.cmd`). To działa, bo polityka dotyczy plików skryptów, a nie poleceń |
| „Za mało miejsca na celu” | Użyj większego dysku albo zwolnij miejsce |
| „Dysk USB musi być w NTFS” | Sformatuj dysk w NTFS (utracisz jego zawartość) |
| Błąd połączenia z udziałem | Sprawdź adres, użytkownika, hasło i dostęp do sieci; przetestuj `net use` ręcznie |
| Kod 1 i komunikat `wbadmin` | Zobacz `log.txt` w folderze kopii oraz szczegółowy log systemu: `C:\Windows\Logs\WindowsBackup\Backup-<data>.log` |

## Bezpieczeństwo

- Kopia całego systemu niczego nie pobiera i niczego nie wysyła w sieć (poza zapisem na wskazany udział). Instalacja kopii codziennej pobiera wyłącznie restic z oficjalnego wydania GitHub (wersja i SHA256 przypięte w `restic-version.json`); nic nie jest wysyłane na zewnątrz.
- Zmiany w systemie: połączenie sieciowe na czas pracy, migawki VSS tworzone przez `wbadmin`, pliki na nośniku docelowym.
- Obraz zawiera cały system, w tym dane i zapisane hasła. Chroń nośnik jak dane produkcyjne.
- Przed uruchomieniem zawsze weryfikuj sumę SHA256 pobranego ZIP-a.

## Licencja

MIT, zobacz `LICENSE`.
