#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/production_projects}"

usage() {
  cat <<'EOF'
Użycie:
  ./production_manager.sh list
  ./production_manager.sh setup <projekt>
  ./production_manager.sh update <projekt>
  ./production_manager.sh status <projekt>
  ./production_manager.sh restart <projekt>
  ./production_manager.sh logs <projekt> [linijek]

Konfiguracje aplikacji znajdują się w katalogu production_projects/<nazwa>.env.
Dodaj nowy plik, aby obsłużyć kolejny projekt.
EOF
}

list_projects() {
  local found=0
  shopt -s nullglob
  for file in "${CONFIG_DIR}"/*.env; do
    found=1
    basename "${file}" .env
  done
  shopt -u nullglob
  if [[ ${found} -eq 0 ]]; then
    echo "Brak projektów w ${CONFIG_DIR}"
  fi
}

require_project_arg() {
  if [[ $# -lt 1 ]]; then
    echo "Podaj nazwę projektu." >&2
    exit 1
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Ta komenda wymaga uprawnień roota (sudo)." >&2
    exit 1
  fi
}

PROJECT_NAME=""
CONFIG_PATH=""

load_project() {
  PROJECT_NAME="$1"
  CONFIG_PATH="${CONFIG_DIR}/${PROJECT_NAME}.env"
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "Nie znaleziono pliku ${CONFIG_PATH}" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${CONFIG_PATH}"

  APP_NAME="${APP_NAME:-${PROJECT_NAME}}"
  REQUIRED_VARS=(
    REPO_SSH APP_USER APP_DIR REPO_DIR VENV_DIR
    PYTHON_BIN WSGI_APP SERVICE_NAME GUNICORN_BIND
    DOMAIN SSH_DIR LOG_DIR NGINX_SITE
  )
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      echo "Brak wartości ${var} w ${CONFIG_PATH}" >&2
      exit 1
    fi
  done

  DEPLOY_KEY="${DEPLOY_KEY:-${SSH_DIR}/id_ed25519}"
  URL_PREFIX="${URL_PREFIX:-}"
  NGINX_STRATEGY="${NGINX_STRATEGY:-standalone}"
  EXTRA_PIP_PACKAGES="${EXTRA_PIP_PACKAGES:-flask gunicorn}"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    "${PYTHON_BIN}" python3-venv python3-pip \
    git nginx ca-certificates openssh-client
}

ensure_user_and_dirs() {
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    local current_home
    current_home="$(getent passwd "${APP_USER}" | cut -d: -f6 || true)"
    if [[ "${current_home}" != "${APP_DIR}" ]]; then
      if [[ ! -e "${APP_DIR}" || -z "$(ls -A "${APP_DIR}" 2>/dev/null)" ]]; then
        usermod -d "${APP_DIR}" -m "${APP_USER}"
      else
        usermod -d "${APP_DIR}" "${APP_USER}"
      fi
    fi
  else
    adduser --system --group --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
  fi

  install -d -o "${APP_USER}" -g "${APP_USER}" "${APP_DIR}" "${REPO_DIR}"
  install -d -o "${APP_USER}" -g www-data "${LOG_DIR}"
  chmod 750 "${LOG_DIR}"
}

setup_ssh() {
  install -d -m 700 -o "${APP_USER}" -g "${APP_USER}" "${SSH_DIR}"
  if [[ ! -f "${DEPLOY_KEY}" ]]; then
    sudo -u "${APP_USER}" ssh-keygen -t ed25519 -C "deploy-${SERVICE_NAME}@$(hostname -f)" -f "${DEPLOY_KEY}" -N ""
    echo ">>> Dodaj ten klucz do GitHuba (Deploy key, read-only):"
    cat "${DEPLOY_KEY}.pub"
  fi
  chmod 600 "${DEPLOY_KEY}"; chown "${APP_USER}:${APP_USER}" "${DEPLOY_KEY}"
  chmod 644 "${DEPLOY_KEY}.pub"; chown "${APP_USER}:${APP_USER}" "${DEPLOY_KEY}.pub"

  ssh-keyscan -H github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null || true
  chown "${APP_USER}:${APP_USER}" "${SSH_DIR}/known_hosts" 2>/dev/null || true
  chmod 644 "${SSH_DIR}/known_hosts" 2>/dev/null || true

  mkdir -p ~root/.ssh && chmod 700 ~root/.ssh
  ssh-keyscan -H github.com >> ~root/.ssh/known_hosts 2>/dev/null || true
  chmod 644 ~root/.ssh/known_hosts

  if [[ ! -f "${SSH_DIR}/config" ]] || ! grep -q "IdentityFile ${DEPLOY_KEY}" "${SSH_DIR}/config"; then
    cat > "${SSH_DIR}/config" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ${DEPLOY_KEY}
  IdentitiesOnly yes
EOF
    chown "${APP_USER}:${APP_USER}" "${SSH_DIR}/config"
    chmod 600 "${SSH_DIR}/config"
  fi
}

sync_repo() {
  if [[ -d "${REPO_DIR}/.git" ]]; then
    sudo -u "${APP_USER}" -H git -C "${REPO_DIR}" fetch --all --prune
    local branch
    branch="$(sudo -u "${APP_USER}" -H git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD || echo main)"
    sudo -u "${APP_USER}" -H git -C "${REPO_DIR}" reset --hard "origin/${branch}" || \
      sudo -u "${APP_USER}" -H git -C "${REPO_DIR}" checkout -B main origin/main
  elif [[ -z "$(ls -A "${REPO_DIR}" 2>/dev/null)" ]]; then
    sudo -u "${APP_USER}" -H git clone --depth 1 "${REPO_SSH}" "${REPO_DIR}"
  else
    echo "Katalog ${REPO_DIR} istnieje i nie jest repozytorium git." >&2
    exit 1
  fi
}

setup_virtualenv() {
  if [[ ! -d "${VENV_DIR}" ]]; then
    sudo -u "${APP_USER}" "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  fi
  sudo -u "${APP_USER}" "${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel
  if [[ -f "${REPO_DIR}/requirements.txt" ]]; then
    sudo -u "${APP_USER}" "${VENV_DIR}/bin/python" -m pip install -r "${REPO_DIR}/requirements.txt"
  fi
  if [[ -n "${EXTRA_PIP_PACKAGES:-}" ]]; then
    sudo -u "${APP_USER}" "${VENV_DIR}/bin/python" -m pip install ${EXTRA_PIP_PACKAGES}
  fi
}

write_systemd_unit() {
  local service_path="/etc/systemd/system/${SERVICE_NAME}.service"
  {
    echo "[Unit]"
    echo "Description=Gunicorn - Flask app (${SERVICE_NAME})"
    echo "After=network.target"
    echo
    echo "[Service]"
    echo "User=${APP_USER}"
    echo "Group=www-data"
    echo "WorkingDirectory=${REPO_DIR}"
    echo "Environment=PATH=${VENV_DIR}/bin"
    echo "Environment=VIRTUAL_ENV=${VENV_DIR}"
    if [[ -n "${URL_PREFIX}" ]]; then
      echo "Environment=SCRIPT_NAME=${URL_PREFIX}"
    fi
    echo "Environment=FORWARDED_ALLOW_IPS=*"
    echo
    echo "ExecStart=${VENV_DIR}/bin/python -m gunicorn --workers 3 --bind ${GUNICORN_BIND} ${WSGI_APP}"
    echo
    echo "Restart=always"
    echo "RestartSec=5"
    echo "TimeoutStartSec=300"
    echo
    echo "StandardOutput=append:${LOG_DIR}/stdout.log"
    echo "StandardError=append:${LOG_DIR}/stderr.log"
    echo
    echo "NoNewPrivileges=true"
    echo "PrivateTmp=true"
    echo "ProtectSystem=full"
    echo "ProtectHome=true"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "${service_path}"
}

configure_nginx_prefix() {
  if [[ -z "${URL_PREFIX}" ]]; then
    echo "NGINX_STRATEGY=prefix wymaga URL_PREFIX." >&2
    exit 1
  fi
  [[ -f "${NGINX_SITE}" ]] || { echo "Brak ${NGINX_SITE}" >&2; exit 1; }
  [[ ! -f "${NGINX_SITE}.bak" ]] && cp "${NGINX_SITE}" "${NGINX_SITE}.bak"

  local begin_marker="# --- ${SERVICE_NAME} path prefix ---"
  local end_marker="# --- end ${SERVICE_NAME} ---"
  if grep -q "${begin_marker}" "${NGINX_SITE}"; then
    awk -v begin="${begin_marker}" -v end="${end_marker}" '
      BEGIN{skip=0}
      index($0, begin){skip=1; next}
      index($0, end){skip=0; next}
      skip==1{next}
      {print}
    ' "${NGINX_SITE}" > "${NGINX_SITE}.tmp" && mv "${NGINX_SITE}.tmp" "${NGINX_SITE}"
  fi

  local domain_regex
  domain_regex="$(printf '%s\n' "${DOMAIN}" | sed 's/[][\\.^$*+?{}()|]/\\&/g')"
  local prefix_regex
  prefix_regex="$(printf '%s\n' "${URL_PREFIX}" | sed 's/[][\\.^$*+?{}()|]/\\&/g')"
  if ! grep -Eq "location[[:space:]]+(\^~|=)?[[:space:]]*${prefix_regex}(/|[[:space:]]|\{)" "${NGINX_SITE}"; then
    awk -v bind="${GUNICORN_BIND}" -v prefix="${URL_PREFIX}" -v name="${SERVICE_NAME}" -v domain="${domain_regex}" '
      BEGIN{ins=0}
      {print}
      /server_name/ && $0 ~ domain && ins==0 {
        print "    # --- " name " path prefix ---";
        print "    location = " prefix " { return 301 " prefix "/; }";
        print "    location ^~ " prefix "/ {";
        print "        proxy_pass http://" bind "/;";
        print "        proxy_set_header Host $host;";
        print "        proxy_set_header X-Real-IP $remote_addr;";
        print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;";
        print "        proxy_set_header X-Forwarded-Proto $scheme;";
        print "        proxy_set_header X-Script-Name " prefix ";";
        print "        proxy_set_header X-Forwarded-Prefix " prefix ";";
        print "        proxy_redirect off;";
        print "        proxy_read_timeout 300; proxy_connect_timeout 60; proxy_send_timeout 300;";
        print "    }";
        print "    # --- end " name " ---";
        ins=1
      }
    ' "${NGINX_SITE}" > "${NGINX_SITE}.tmp" && mv "${NGINX_SITE}.tmp" "${NGINX_SITE}"
  fi
}

configure_nginx_standalone() {
  cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 25m;

    location / {
        proxy_pass http://${GUNICORN_BIND};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 300;
        proxy_connect_timeout 60;
        proxy_send_timeout 300;
    }
}
EOF
  ln -sf "${NGINX_SITE}" "/etc/nginx/sites-enabled/${SERVICE_NAME}.conf"
}

configure_nginx() {
  case "${NGINX_STRATEGY}" in
    prefix) configure_nginx_prefix ;;
    standalone) configure_nginx_standalone ;;
    none) ;;
    *)
      echo "Nieznana wartość NGINX_STRATEGY=${NGINX_STRATEGY}" >&2
      exit 1
      ;;
  esac
}

reload_services() {
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"
  nginx -t
  systemctl enable nginx
  systemctl reload nginx || systemctl restart nginx
}

show_status() {
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

show_summary() {
  local public_path="/"
  if [[ -n "${URL_PREFIX}" ]]; then
    public_path="${URL_PREFIX%/}/"
  fi
  cat <<INFO

Gotowe dla ${APP_NAME}!

URL:            http://${DOMAIN}${public_path}
Repo:           ${REPO_DIR}
Venv:           ${VENV_DIR}
SSH:            ${SSH_DIR} (użytkownik ${APP_USER})
Logi:           ${LOG_DIR}
Unit:           /etc/systemd/system/${SERVICE_NAME}.service
Nginx:          ${NGINX_SITE}

INFO
}

tail_logs() {
  local lines="${1:-100}"
  for stream in stdout stderr; do
    local file="${LOG_DIR}/${stream}.log"
    if [[ -f "${file}" ]]; then
      echo "--- ${stream}.log (${lines} linii) ---"
      tail -n "${lines}" "${file}"
      echo
    else
      echo "Brak ${file}"
    fi
  done
}

ACTION="${1:-}"
case "${ACTION}" in
  list)
    list_projects
    ;;
  setup)
    require_project_arg "${@:2}"
    require_root
    load_project "${2}"
    install_packages
    ensure_user_and_dirs
    setup_ssh
    sync_repo
    setup_virtualenv
    write_systemd_unit
    configure_nginx
    reload_services
    show_status
    show_summary
    ;;
  update)
    require_project_arg "${@:2}"
    require_root
    load_project "${2}"
    ensure_user_and_dirs
    sync_repo
    setup_virtualenv
    write_systemd_unit
    configure_nginx
    reload_services
    show_status
    ;;
  status)
    require_project_arg "${@:2}"
    load_project "${2}"
    show_status
    ;;
  restart)
    require_project_arg "${@:2}"
    require_root
    load_project "${2}"
    systemctl restart "${SERVICE_NAME}"
    nginx -t
    systemctl reload nginx || systemctl restart nginx
    show_status
    ;;
  logs)
    require_project_arg "${@:2}"
    load_project "${2}"
    tail_logs "${3:-100}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
