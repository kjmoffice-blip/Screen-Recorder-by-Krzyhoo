# Weryfikacja — 22.11.2026

Środowisko: macOS 26.7.1, Apple Silicon, Apple Swift 6.4.

- `bash Scripts/build.sh`: zbudowano Universal arm64/x86_64, podpis ad hoc poprawny.
- `bash Scripts/test.sh`: wszystkie testy writera zakończone powodzeniem.
- Sześć kombinacji pełny ekran/region × bez audio/system/mikrofon na syntetycznych
  danych: poprawne H.264/AAC, dekodowanie początku i końca, czas i geometria.
- Zweryfikowano opóźnienie sygnału audio, statyczną klatkę oraz sprzątanie pustych
  i anulowanych plików. Syntetyczny test audio nie nagrywa fizycznego mikrofonu.
- Kod aplikacji i testów odpowiada zachowanym źródłom 1.0.1. Zmieniono dokumentację,
  licencję i listę dokumentów dołączanych przez skrypt pakowania.

Testy ikon i kodeków wymagały uruchomienia poza sandboxem narzędzia testowego.
Swift 6.4 zgłasza ostrzeżenia Sendable/capture w istniejącym kodzie; kompilacja
w domyślnym trybie skryptu kończy się powodzeniem. Nie wykonywano ponownego
nagrania pulpitu/mikrofonu, fizycznego zaznaczania ani testu fizycznego Maca Intel.
Nie wykonano nowej notaryzacji; nowa lokalna kompilacja ma podpis ad hoc.
