# Screen Recorder by Krzyhoo

Natywna aplikacja macOS w pasku menu do nagrywania całego głównego ekranu albo
zaznaczonego prostokąta jednego monitora. Zapisuje MP4 H.264 (do 30 klatek/s),
opcjonalnie z dźwiękiem systemowym stereo lub mikrofonem mono, AAC 48 kHz.
Źródła audio wybiera się przed rozpoczęciem; nie są miksowane. Domyślnie bez audio.

Kamera miga na czerwono podczas nagrania całego ekranu i na niebiesko podczas
nagrania fragmentu; obok jest czas. Escape anuluje zaznaczanie. „Zatrzymaj i zapisz”
zapisuje film w systemowych Pobranych, a „Pokaż ostatni film” odsłania go w Finderze.
Unikalna nazwa chroni istniejące filmy. Normalny start pokazuje wyłącznie ikonę
w pasku menu, bez ikony w Docku. Nie ma pauzy ani autostartu.

Film jest najpierw zapisywany tymczasowo. Dopiero po zamknięciu kodera i kontroli
ścieżek, czasu oraz dekodowania początku i końca otrzymuje końcową nazwę MP4.
Awaria lub wymuszone zakończenie może pozostawić niedokończony plik tymczasowy.
Program działa lokalnie, bez kont, backendu, sieci i telemetrii.

## Wymagania i budowanie

macOS 13 Ventura lub nowszy, Xcode Command Line Tools z kompilatorem Swift i SDK
macOS 13+. AppKit, ScreenCaptureKit i AVFoundation, bez zewnętrznych zależności.

```sh
bash Scripts/build.sh
open "build/Screen Recorder by Krzyhoo.app"
bash Scripts/test.sh
```

Skrypt buduje Universal (arm64/x86_64) i podpisuje ad hoc z Hardened Runtime.
`test.sh` sprawdza kodowanie i dekodowanie H.264/AAC, sześć kombinacji obrazu/audio,
synchronizację, statyczny ekran, geometrię Retina i puste/anulowane pliki na
syntetycznych danych. Nagrania testowe powstają tylko w ignorowanym `build/`.

Do rzeczywistego nagrywania potrzebna jest zgoda macOS na ekran, a dla mikrofonu
osobna zgoda. Przy zmianie zgód może być wymagany restart. Program nie resetuje
TCC i nie omija zabezpieczeń. Chronione treści mogą nie zostać nagrane.

`Scripts/test-capture.sh` to opcjonalny test integracyjny: zakłada istniejącą
instalację 1.0.1 w `/Applications`, zapisuje rzeczywiste filmy do Pobranych i może
odtworzyć ton testowy. Nie jest częścią podstawowego testu źródeł. Dostępne są
parametry `--smoke-full`, `--smoke-region`, `--audio none|system|microphone`,
`--seconds 3`, `--report /pełna/ścieżka.txt`; wymagają tych samych zgód co aplikacja.

`bash Scripts/package.sh` tworzy lokalną paczkę aplikacji, DMG, źródła i sumy
w nowym folderze Pobranych. Nie wykonuje podpisu Developer ID ani notaryzacji.

## Weryfikacja

Bieżące wyniki: `VERIFICATION.md`. Nie wykonywano ponownej próby rzeczywistego
ekranu i mikrofonu, ręcznego zaznaczania ani fizycznego komputera Intel.

## Publikacja i prawa

Repozytorium zawiera źródła i narzędzia deweloperskie. Nie zawiera instalatora,
certyfikatów, kluczy, prywatnych zrzutów ani nagrań. Kod aplikacji jest udostępniony na licencji **MIT** (`LICENSE`).
Informacje o prawach i zależnościach: `RIGHTS.md`.

Wcześniejsze wydanie binarne 1.0.1 było podpisane Developer ID i uzyskało
notaryzację Apple w październiku 2026. To informacja historyczna, która nie
obejmuje nowych lokalnych kompilacji z tego repozytorium. Lokalna kompilacja
nie jest automatycznie podpisana Developer ID ani notaryzowana. Publiczna
publikacja kodu 22.11.2026 nie zmienia funkcji, wyglądu ani wersji aplikacji.
