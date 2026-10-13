# Odtwarzanie kopii win_resurect

Kopia leży na nośniku w katalogu `WindowsImageBackup\<nazwa komputera>` (USB: w katalogu głównym dysku; SMB: w folderze `WinResurect\<komputer>_<data>` na udziale). Dokumenty tej kopii (`manifest.txt`, `log.txt`, `PRZYWRACANIE.txt`, `drivers\`) są w folderze `WinResurect\<komputer>_<data>`.

## Pełne odtworzenie (nadpisze dysk komputera!)

1. Podłącz nośnik z kopią (USB) albo upewnij się, że udział sieciowy jest dostępny.
2. Uruchom środowisko odzyskiwania: Ustawienia → System → Odzyskiwanie → Uruchamianie zaawansowane → Uruchom ponownie teraz (albo uruchom z pendrive'a instalacyjnego Windows i wybierz Napraw komputer).
3. Rozwiązywanie problemów → Opcje zaawansowane → Więcej opcji odzyskiwania → Odzyskiwanie obrazu systemu.
4. USB: wybierz obraz systemu z listy. SMB: Zaawansowane → Wyszukaj obraz systemu w sieci i podaj ścieżkę udziału oraz dane dostępu.
5. Jeśli dysk był szyfrowany BitLockerem, przygotuj klucz odzyskiwania (narzędzie go nie zapisuje).
6. Potwierdź odtworzenie i poczekaj na zakończenie. Komputer uruchomi się ponownie.

## Pojedyncze pliki (bez odtwarzania całości)

1. Znajdź plik `.vhdx` w `WindowsImageBackup\<komputer>\Backup <data>`.
2. W PowerShellu jako administrator: `Mount-DiskImage -ImagePath "<pełna ścieżka do .vhdx>" -Access ReadOnly`.
3. Skopiuj potrzebne pliki z nowego dysku, który pojawi się w Eksploratorze.
4. Odmontuj: `Dismount-DiskImage -ImagePath "<pełna ścieżka do .vhdx>"`.

## Uwagi

- Odtwarzanie na innym sprzęcie nie jest gwarantowane. Pomocne mogą być sterowniki wyeksportowane do `drivers\`.
- Stare serwery plików wymagające SMB1 nie zostaną zamontowane w środowisku odzyskiwania. Użyj wtedy kopii na USB.
- Obraz zawiera całość systemu, w tym dane i zapisane hasła; chroń nośnik.
