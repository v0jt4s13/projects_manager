# Production Projects Config

W tym katalogu znajduje się konfiguracja każdej aplikacji obsługiwanej przez `production_manager.sh`. Każdy plik `<nazwa>.env` opisuje pojedynczy projekt, np. `learningcenter.env`.

## Kluczowe zmienne

- `APP_NAME` – nazwa przyjazna używana w komunikatach.
- `REPO_SSH` – adres SSH do repozytorium Git.
- `APP_USER` – użytkownik systemowy, pod którym działa aplikacja.
- `APP_DIR`, `REPO_DIR`, `VENV_DIR` – ścieżki do katalogów systemowego home, kodu i wirtualnego środowiska.
- `PYTHON_BIN` – interpreter używany do tworzenia venv (`python3.11` itp.).
- `WSGI_APP` – odniesienie do aplikacji Flask dla Gunicorna, np. `app:create_app()`.
- `SERVICE_NAME` – nazwa jednostki systemd.
- `GUNICORN_BIND` – adres/port, pod którym nasłuchuje Gunicorn (np. `127.0.0.1:8003`).
- `DOMAIN`, `URL_PREFIX` – konfiguracja domeny/prefiksu Nginx; przy `URL_PREFIX` ustaw `NGINX_STRATEGY=prefix`.
- `SSH_DIR`, `DEPLOY_KEY` – lokalizacja klucza deploy; jeśli `DEPLOY_KEY` pominięty, przyjmowana jest ścieżka `SSH_DIR/id_ed25519`.
- `LOG_DIR` – katalog logów (`stdout.log`, `stderr.log`).
- `NGINX_SITE` – plik konfiguracyjny Nginx (np. `/etc/nginx/sites-available/moderacja.conf`).
- `NGINX_STRATEGY` – `prefix`, `standalone` lub `none`, decyduje o sposobie wpisania reverse proxy.
- `EXTRA_PIP_PACKAGES` – dodatkowe pakiety instalowane w venv, gdy projekt nie posiada kompletnego `requirements.txt`.

## Dodanie nowego projektu

1. Sklonuj jeden z istniejących plików `.env` i zmień wartości zmiennych.
2. Upewnij się, że ścieżki i porty nie kolidują z innymi usługami.
3. Uruchom `./production_manager.sh setup <nazwa_pliku_bez_env>` aby przeprowadzić pierwsze wdrożenie.

Pliki `.env` mają format zgodny z `bash`, więc możesz korzystać z interpolacji (`${APP_DIR}/app`). Pamiętaj, by nie commitować sekretów — skrypt zakłada generowanie kluczy deploy na serwerze.
