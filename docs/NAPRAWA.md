# Naprawa i czyszczenie systemu

> Wersja przedpremierowa: zaimplementowana i przetestowana jednostkowo, jeszcze nie na prawdziwym Windows.

## Zasady

Narzędzie nie robi niczego po cichu. `audit` tylko czyta. `repair` pokazuje plan każdego modułu i czeka na `t`. Flaga `-Yes` jest odrzucana (kod 2): decyzja ma należeć do technika na każdym komputerze. Nic nie jest pobierane z internetu i nic nie jest wysyłane.

## Audyt

```bat
Start.cmd -Action audit
```

Zbiera: stan i zużycie dysków fizycznych, wolne miejsce, ile można odzyskać (Temp, cache Windows Update, kosz, hibernacja, zrzuty, WinSxS), średni czas ostatnich startów, pozycje autostartu, `DISM /CheckHealth` i ostatni wynik `sfc` z CBS.log, stan Windows Update, RAM i restarty awaryjne z 30 dni. Każda grupa ma ocenę OK / UWAGA / ZŁY albo BRAK DANYCH z powodem (np. brak uprawnień, maszyna wirtualna bez SMART, inny język systemu). Wyniki: `audit.json` i `raport.txt` w `C:\ProgramData\WinResurect\repair\<data>\` (dostęp tylko SYSTEM i Administratorzy).

## Naprawa

```bat
Start.cmd -Action repair -ImageDate 2026-10-15
Start.cmd -Action repair -Modules cleanup,startup
Start.cmd -Action repair -SkipBackupCheck "klient ma kopię w chmurze"
```

Kontrola wstępna odmawia pracy (kod 2), gdy: brak uprawnień administratora, komputer na baterii, czeka restart, mniej niż 2 GB wolnego miejsca albo **brak świeżej kopii**. Świeża kopia to: `last-run.json` kopii codziennej z ostatnim sukcesem do 48 h i statusem innym niż `fail`, albo obraz systemu z fazy 0 podany jako `-ImageDate RRRR-MM-DD` (do 30 dni; obraz nie zostawia śladu na komputerze, więc datę podaje technik). `-SkipBackupCheck "powód"` pomija kontrolę, a powód trafia do raportu. Potem powstaje punkt przywracania; jeśli system odmówi (limit jednego na 24 h, wyłączona ochrona systemu), narzędzie pyta, czy kontynuować.

Moduły, zawsze w tej kolejności (od najmniej do najbardziej inwazyjnego):

| Moduł | Co robi | Cofanie |
|---|---|---|
| `system-repair` | `DISM /RestoreHealth`, `sfc /scannow`, `DISM /CheckHealth`; limit 60 min na krok. Gdy się nie uda, podpowiada nośnik jako Source. | nie dotyczy |
| `windows-update` | zatrzymuje BITS, wuauserv, appidsvc, cryptsvc; **zmienia nazwę** `SoftwareDistribution` i `catroot2` na `*.bak-<data>`; `netsh winsock reset`; uruchamia usługi, które działały. Nie instaluje aktualizacji i nie restartuje. Kopie starsze niż 14 dni są usuwane. | `-Undo windows-update` |
| `cleanup` | czyści Temp (tylko pliki starsze niż 7 dni), cache Windows Update, zrzuty, `DISM /StartComponentCleanup` (bez `/ResetBase`). Kosz i hibernacja: osobne pytania. Nie rusza Pobranych, Dokumentów, Pulpitu ani profili przeglądarek. | brak |
| `startup` | numerowana lista autostartu; ty wskazujesz numery (`1,3-5`). Wyłącza, nie usuwa. Pozycje Microsoft, oprogramowanie antywirusowe i skróty z folderu Autostart są chronione. | `-Undo startup` |

Po wykonaniu któregokolwiek modułu narzędzie robi drugi audyt i pokazuje różnicę (odzyskane miejsce, czas startu, liczba pozycji autostartu, integralność).

## Cofanie

```bat
Start.cmd -Action repair -Undo startup
Start.cmd -Action repair -Undo windows-update
```

Cofa zmiany z najnowszego przebiegu, który jeszcze ich nie cofał. `windows-update` przywraca foldery pod starą nazwą, o ile nowy folder jest jeszcze mały; jeśli Windows zdążył go wypełnić, zostawia kopię `.bak-*` i mówi o tym.

## Kody wyjścia

0 wszystko w porządku, 1 co najmniej jeden moduł zakończył się błędem, 2 odmowa lub zły parametr, 3 przerwano.

## Rozwiązywanie problemów

| Objaw | Co zrobić |
|---|---|
| „Brak świeżej kopii…" | wykonaj kopię codzienną (`Start.cmd -Action status`) albo obraz i podaj `-ImageDate` |
| BRAK DANYCH przy SMART | uruchom jako administrator; na maszynie wirtualnej liczniki SMART nie istnieją |
| `nie rozpoznano wyniku` przy DISM/sfc | system w języku innym niż polski i angielski; sprawdź `C:\Windows\Logs\CBS\CBS.log` |
| Brak punktu przywracania | włącz Ochronę systemu dla dysku C: albo poczekaj dobę od poprzedniego punktu |
| `sfc` mówi, że nie naprawił plików | uruchom `DISM /Online /Cleanup-Image /RestoreHealth /Source:<ISO>\sources\install.wim /LimitAccess` i powtórz moduł |
| Przekroczono limit czasu | polecenie mogło działać dalej w tle; poczekaj na jego koniec w Menedżerze zadań |

## Czego narzędzie nie robi

Nie pobiera ani nie uruchamia zewnętrznych narzędzi (WinUtil, Autoruns, skanery malware), nie czyści rejestru, nie instaluje aktualizacji, nie wymusza restartu i nie wysyła raportów. Kroki ręczne są w [WIZYTA.md](WIZYTA.md).
