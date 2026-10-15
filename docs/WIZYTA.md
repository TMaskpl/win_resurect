# Wizyta serwisowa: checklista

1. **Przed wizytą.** Zgoda klienta na zakres. Ustal, czy zdalnie (RustDesk), czy na miejscu.
2. **Kopia.** `Start.cmd -Action status` (kopia codzienna) albo obraz systemu (README, sekcja „Kopia całego systemu"). Bez świeżej kopii nie przechodzimy dalej.
3. **Audyt.** `Start.cmd -Action audit`. Omów z klientem wnioski, zwłaszcza to, co może być wyłączone, bo ktoś tego używa (drukowanie, Bluetooth, Xbox, programy w autostarcie).
4. **Naprawa.** `Start.cmd -Action repair -ImageDate RRRR-MM-DD` (albo bez daty, gdy kopia codzienna jest świeża). Kolejność modułów: `system-repair`, `windows-update`, `cleanup`, `startup`.
5. **Kroki ręczne** (narzędzie ich nie obejmuje; przed użyciem komercyjnym sprawdź licencję):
   - malware i adware: Microsoft Defender Offline Scan (wbudowany); AdwCleaner; Malwarebytes tylko w wersji dozwolonej do użytku komercyjnego;
   - sterowniki karty graficznej: DDU, potem sterownik od producenta (nie „driver updatery");
   - pamięć: Diagnostyka pamięci Windows lub MemTest86;
   - dokładne odinstalowanie programów: Bulk Crap Uninstaller;
   - prywatność i debloat: WinUtil, O&O ShutUp10++ (po punkcie przywracania i rozmowie z klientem);
   - diagnostyka sprzętu: CrystalDiskInfo, HWiNFO (sprawdź warunki licencji dla użytku komercyjnego).
6. **Audyt po.** Narzędzie robi go samo po `repair`. Wydrukuj lub zapisz `raport.txt` dla klienta.
7. **Zamknięcie.** Po dużych zmianach zrób nowy obraz bazowy, upewnij się, że kopia codzienna jest włączona, i dopisz wpis do dziennika.
