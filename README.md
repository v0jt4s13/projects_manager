# Production Manager

Skrypt `production_manager.sh` automatuzuje zarządzanie wieloma aplikacjami Flask na serwerze produkcyjnym. Każdy projekt ma własny plik konfiguracyjny w katalogu `production_projects/<nazwa>.env`.

## Użycie

```bash
./production_manager.sh list
```
: wypisuje dostępne projekty na podstawie plików `.env`.

```bash
./production_manager.sh setup <projekt>
```
: pełne wdrożenie wskazanej aplikacji (pakiety systemowe, użytkownik, repozytorium, wirtualne środowisko, systemd, Nginx). Wymaga `sudo`.

```bash
./production_manager.sh update <projekt>
```
: odświeża kod, zależności oraz ponownie generuje unit i konfigurację Nginx bez ponownego instalowania pakietów systemowych. Również wymaga `sudo`. Jeżeli w pliku `<projekt>.env` ustawisz `BUILD_CMD` (opcjonalnie `BUILD_DIR`), zostanie on uruchomiony podczas `setup` i `update`.

```bash
./production_manager.sh status <projekt>
```
: skrócony status usługi systemd (`systemctl status`).

```bash
./production_manager.sh restart <projekt>
```
: restartuje usługę oraz przeładowuje Nginxa. Wymaga `sudo`.

```bash
./production_manager.sh logs <projekt> [linijek]
```
: tail logów aplikacji (`stdout.log` i `stderr.log`). Opcjonalny parametr określa liczbę linii (domyślnie 100).

Pamiętaj, aby skrypt był wykonywalny (`chmod +x production_manager.sh`) oraz aby nowe projekty miały kompletny plik konfiguracyjny w `production_projects/`.
