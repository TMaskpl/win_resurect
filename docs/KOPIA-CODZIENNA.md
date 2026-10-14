# Kopia codzienna wybranych folderów

> Wersja przedpremierowa: zaimplementowana i przetestowana jednostkowo, jeszcze nie sprawdzona na prawdziwym Windows. Kopia całego systemu (obraz) jest opisana w README.

## Jak to działa

Zadanie `WinResurect-Daily` (Harmonogram Windows, konto SYSTEM) uruchamia się codziennie o wybranej godzinie, łączy się z celem (dysk USB po etykiecie albo udział SMB) i wykonuje `restic backup` z migawką VSS. Zapisują się tylko zmiany od poprzedniej kopii. Raz w tygodniu zadanie `WinResurect-Maintenance` usuwa stare migawki według retencji i sprawdza część repozytorium.

Pliki robocze są w `C:\ProgramData\WinResurect\` (dostęp tylko dla SYSTEM i administratorów): `daily.json`, `repo.pass`, `smb.cred` (SMB), `restic.exe`, `last-run.json`, `daily.log`.

## Instalacja

Wiersz poleceń jako administrator w katalogu narzędzia (na dysku lokalnym, nie na dysku docelowym kopii):

```bat
Start.cmd -Action install-daily -Target usb -Label BACKUP
Start.cmd -Action install-daily -Target smb -Share \\nas\share -User uzytkownik
```

1. Dysk USB musi mieć system plików NTFS i **unikalną etykietę** (nadasz ją w Eksploratorze: prawy klik na dysku, Właściwości). Przy SMB hasło wpisujesz po zachęcie.
2. Instalator pobiera restic i sprawdza sumę SHA256. Przy niezgodności przerywa i niczego nie instaluje.
3. Pokazuje **hasło repozytorium** raz. Zapisz je w KeePass, zanim naciśniesz Enter. Bez niego kopii nie da się odczytać.
4. Otwiera `daily.json` w Notatniku: wpisz foldery do kopiowania, zapisz i zamknij.
5. Rejestruje zadania i od razu uruchamia pierwszą kopię (postęp widać na ekranie).

Ponowne uruchomienie `install-daily` aktualizuje cel, a zachowuje listę folderów, wykluczenia, retencję, repozytorium i hasło repozytorium. Godzinę (`-Time 14:30`) i folder repozytorium (`-Folder Nazwa`) zmieniasz tylko, gdy podasz je jawnie; w przeciwnym razie zostają dotychczasowe. Instalacja jest interaktywna (hasło repozytorium trzeba zapisać w KeePass), więc nie ma trybu `-Yes`.

Instalator odmawia pracy, gdy `C:\ProgramData\WinResurect` już istnieje i nie należy do SYSTEM ani Administratorów (ochrona przed podłożeniem plików uruchamianych jako SYSTEM). `restic.exe` jest zawsze instalowany ze zweryfikowanego archiwum, nigdy z istniejącego pliku.

## Plik `daily.json`

```json
{
  "target": { "type": "usb", "label": "BACKUP", "folder": "WinResurectDaily" },
  "folders": ["C:\\Users\\Jan\\Documents", "D:\\Ksiegowosc"],
  "excludes": ["*.tmp", "Thumbs.db", "node_modules"],
  "schedule": { "time": "12:30" },
  "retention": { "daily": 14, "weekly": 8, "monthly": 6 },
  "report": { "enabled": false }
}
```

Dla SMB zamiast etykiety: `"target": { "type": "smb", "share": "\\\\nas\\share", "user": "uzytkownik", "folder": "WinResurectDaily" }`.

- W JSON ukośniki odwrotne podwajasz (`C:\\Dane`).
- Zmiany w `folders`, `excludes` i `retention` działają od **następnego przebiegu**. Zmiana godziny lub celu wymaga ponownego `install-daily`.
- Każdy przebieg waliduje plik. Błąd w pliku kończy się wynikiem `fail` z czytelnym komunikatem, a nie cichym brakiem kopii.
- Folder z listy, który nie istnieje, jest pomijany z ostrzeżeniem (`warn`), a reszta jest kopiowana.
- Repozytorium leży w `<korzeń celu>\WinResurectDaily\<nazwa komputera>`.

## Status

```bat
Start.cmd -Action status
```

Pokazuje wynik ostatniego przebiegu, czas, dodany rozmiar, liczbę migawek i pominięte foldery. Gdy ostatni sukces jest starszy niż 48 godzin (albo go nie ma), wypisuje ostrzeżenie **NIEAKTUALNA**. Kod wyjścia: 0 świeża, 1 nieaktualna lub błąd, 2 nie zainstalowano.

## Odtwarzanie plików

```bat
Start.cmd -Action restore
```

Pokazuje listę migawek, pozwala wskazać migawkę oraz folder lub plik, i przywraca je do **nowego folderu** `Przywrocone_<data>` z pełną strukturą katalogów z migawki. Folder nadrzędny musi leżeć poza kopiowanymi folderami: narzędzie proponuje pierwszy bezpieczny (Pulpit, Pobrane lub korzeń dysku systemowego) i pozwala podać własny. Oryginały nigdy nie są nadpisywane (cel kolidujący z kopiowanym folderem jest odrzucany). Przy SMB narzędzie pyta o hasło ponownie. Na tym samym komputerze narzędzie czyta hasło repozytorium z `repo.pass`. Po awarii, na innym komputerze, użyj `restic` ręcznie (`restic -r <repozytorium> restore latest --target <folder>`) z hasłem zapisanym w KeePass.

## Usuwanie

```bat
Start.cmd -Action remove-daily
```

Usuwa zadania i `C:\ProgramData\WinResurect\` (razem z hasłem repozytorium). **Kopie na nośniku zostają.**

## Rozwiązywanie problemów

| Objaw | Co zrobić |
|---|---|
| „cel niedostępny: nie znaleziono dysku o etykiecie…” | podłącz dysk; sprawdź etykietę w Eksploratorze; zadanie jest skonfigurowane do ponawiania (do dwóch prób co 30 minut; działanie przy niezerowym kodzie wyjścia zostanie potwierdzone na Windows), a w razie potrzeby uruchom `schtasks /run /tn WinResurect-Daily` |
| „więcej niż jeden dysk o etykiecie…” | nadaj dyskom unikalne etykiety |
| „NIEAKTUALNA” w Statusie | zobacz `daily.log` i `last-run.json`; uruchom `schtasks /run /tn WinResurect-Daily` |
| `fail` i komunikat o `daily.json` | popraw plik (ukośniki podwojone, godzina `GG:MM`, ścieżki bezwzględne) |
| `warn` z pominiętymi folderami | usuń nieistniejące foldery z listy albo przywróć je |
| kod 1219 przy SMB | istnieje już połączenie z tym serwerem na innych poświadczeniach: odłącz je poleceniem `net use <udział> /delete` |
| Antywirus blokuje `restic.exe` | dodaj wyjątek dla `C:\ProgramData\WinResurect\restic.exe` |
| „Running scripts is disabled” przy zadaniu | polityka narzucona przez GPO; zadanie trzeba przepiąć na wywołanie przez scriptblock (patrz README) |

## Czego ta funkcja nie robi

Nie wysyła żadnych raportów na zewnątrz (pole `report` jest zarezerwowane na przyszłość), nie kopiuje do chmury, nie obsługuje wielu celów naraz ani baz danych i maszyn wirtualnych, i nie aktualizuje restic automatycznie.
