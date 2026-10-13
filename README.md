# win_resurect

**EN:** A small Windows tool that makes a full system image (via the built-in `wbadmin`) to a USB disk or an SMB share *before* you start repairing a PC, so you can always roll back. Run `Start.cmd`, pick the target, done. Public, MIT, no telemetry.

Narzędzie robi **pełną kopię systemu (obraz) przed naprawą komputera**, na dysk USB albo udział SMB, używając wbudowanego w Windows `wbadmin`. Po nieudanej naprawie możesz wrócić do stanu sprzed ingerencji, a pojedyncze pliki odzyskać bez przywracania całości.

## Wymagania

- Windows 10 lub 11, PowerShell 5.1 (jest w systemie), uprawnienia administratora.
- Cel: dysk USB w **NTFS** (osobny fizyczny dysk) albo udział SMB z prawem zapisu.
- Wolne miejsce na celu co najmniej o 10% większe niż zajęte miejsce na kopiowanych dyskach.
- Laptop podłączony do zasilania. Odłącz zbędne dyski zewnętrzne (każdy stały dysk NTFS trafi do kopii).

## Pobranie i weryfikacja

1. Pobierz ze strony **Releases** plik `win_resurect-<wersja>.zip` oraz `SHA256SUMS.txt`.
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

**Hasło SMB** podajesz po zachęcie (nie jest widoczne) albo przez zmienną `WINRES_PASSWORD` ustawioną tylko na czas uruchomienia. Nigdy nie wpisuj hasła w parametrach ani w plikach.

## Co robi narzędzie

1. Sprawdza uprawnienia, cel, miejsce, BitLocker i zasilanie. Przy błędzie niczego nie zapisuje.
2. Łączy się z udziałem (SMB) na czas pracy.
3. Eksportuje sterowniki (`pnputil`).
4. Tworzy obraz wszystkich lokalnych dysków NTFS (`wbadmin ... -allCritical`).
5. Weryfikuje kopię (lista wersji i obecność pliku obrazu).
6. Zapisuje na nośniku folder `WinResurect\<komputer>_<data>` z plikami `manifest.txt`, `log.txt`, `PRZYWRACANIE.txt` i `drivers\`.
7. Odłącza udział i czyści hasło z pamięci.

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
| „Running scripts is disabled” | Uruchom `Start.cmd` (ma `-ExecutionPolicy Bypass`). Jeśli politykę narzuca GPO i `Start.cmd` nadal się nie uruchamia, otwórz PowerShell jako administrator w katalogu narzędzia i wykonaj dwa polecenia: `Get-Content -Raw .\src\WinResurect.psm1 \| Invoke-Expression`, a potem `Get-Content -Raw .\Invoke-Resurect.ps1 \| Invoke-Expression` |
| „Za mało miejsca na celu” | Użyj większego dysku albo zwolnij miejsce |
| „Dysk USB musi być w NTFS” | Sformatuj dysk w NTFS (utracisz jego zawartość) |
| Błąd połączenia z udziałem | Sprawdź adres, użytkownika, hasło i dostęp do sieci; przetestuj `net use` ręcznie |
| Kod 1 i komunikat `wbadmin` | Zobacz `log.txt` w folderze kopii i dokumentację `wbadmin` |

## Bezpieczeństwo

- Narzędzie niczego nie pobiera w czasie działania i niczego nie wysyła w sieć (poza zapisem na wskazany udział).
- Zmiany w systemie: połączenie sieciowe na czas pracy, migawki VSS tworzone przez `wbadmin`, pliki na nośniku docelowym.
- Obraz zawiera cały system, w tym dane i zapisane hasła. Chroń nośnik jak dane produkcyjne.
- Przed uruchomieniem zawsze weryfikuj sumę SHA256 pobranego ZIP-a.

## Licencja

MIT, zobacz `LICENSE`.
