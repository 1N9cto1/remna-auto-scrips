#!/usr/bin/env bash

# ==============================================================================
# Script: deploy.sh
# Description: Remnawave Infrastructure Interactive Installer with Caddy Proxy
# Reference: https://docs.rw/install/remnawave-panel
# Architecture: Inspired by eGamesAPI/remnawave-reverse-proxy
# ==============================================================================

set -euo pipefail

# --- ANSI Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

generate_secret() {
    openssl rand -hex 24
}

# --- System Checks & Pre-requisites ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
       log_error "Этот скрипт должен быть запущен от имени root."
       exit 1
    fi
}

install_dependencies() {
    log_info "Проверка системных зависимостей..."
    
    # 1. Check/Install Docker & Docker Compose V2
    if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
        log_warn "Docker или Docker Compose V2 не найдены. Установка через official script..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        log_success "Docker успешно установлен."
    else
        log_info "Docker и Docker Compose V2 уже установлены."
    fi

    # 2. Check/Install Fail2ban
    if ! command -v fail2ban-client &> /dev/null; then
        log_warn "Fail2ban не найден. Установка..."
        if command -v apt &> /dev/null; then
            apt update && apt install -y fail2ban
        elif command -v dnf &> /dev/null; then
            dnf install -y fail2ban
        fi

        log_info "Настройка базовой защиты SSH в /etc/fail2ban/jail.local..."
        cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
EOF
        systemctl restart fail2ban
        systemctl enable fail2ban
        log_success "Fail2ban установлен и настроен."
    else
        log_info "Fail2ban уже установлен."
    fi
}

# --- Module 1: Remnawave Panel + Caddy ---
install_panel() {
    log_info "=== Установка Remnawave Panel + Caddy ==="
    
    read -rp "Введите домен для Панели (например, panel.example.com): " PANEL_DOMAIN
    read -rp "Введите Email для SSL Let's Encrypt: " SSL_EMAIL
    
    read -rp "Имя пользователя PostgreSQL [remnawave]: " DB_USER
    DB_USER=${DB_USER:-remnawave}
    
    read -rp "Имя базы данных PostgreSQL [remnawave]: " DB_NAME
    DB_NAME=${DB_NAME:-remnawave}
    
    read -rsp "Пароль PostgreSQL (оставьте пустым для генерации): " DB_PASS
    echo
    [[ -z "$DB_PASS" ]] && DB_PASS=$(generate_secret) && log_info "Сгенерирован пароль DB: $DB_PASS"

    read -rsp "Пароль Redis (оставьте пустым для генерации): " REDIS_PASS
    echo
    [[ -z "$REDIS_PASS" ]] && REDIS_PASS=$(generate_secret) && log_info "Сгенерирован пароль Redis: $REDIS_PASS"

    # Secrets generation based on official docs
    APP_SECRET=$(generate_secret)
    METRICS_PASS=$(generate_secret)
    WEBHOOK_SECRET_HEADER=$(generate_secret)

    WORK_DIR="/opt/remnawave-panel"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    log_info "Создание .env..."
    cat <<EOF > .env
# Application
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@postgres:5432/${DB_NAME}?schema=public
REDIS_URL=redis://:${REDIS_PASS}@redis:6379/0
JWT_SECRET=${APP_SECRET}
METRICS_PASS=${METRICS_PASS}
WEBHOOK_SECRET_HEADER=${WEBHOOK_SECRET_HEADER}

# Admin Account Prompt Settings
PORT=3000
HOST=0.0.0.0
EOF

    log_info "Создание docker-compose.yml..."
    cat <<EOF > docker-compose.yml
services:
  remnawave:
    image: ghcr.io/remnawave/backend:latest
    container_name: remnawave-panel
    restart: always
    env_file: .env
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    container_name: remnawave-db
    restart: always
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: remnawave-redis
    restart: always
    command: redis-server --requirepass ${REDIS_PASS}
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASS}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  caddy:
    image: caddy:2-alpine
    container_name: remnawave-caddy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - remnawave

volumes:
  postgres_data:
  redis_data:
  caddy_data:
  caddy_config:
EOF

    log_info "Создание Caddyfile..."
    cat <<EOF > Caddyfile
${PANEL_DOMAIN} {
    email ${SSL_EMAIL}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    reverse_proxy 127.0.0.1:3000
}
EOF

    log_info "Запуск сервисов..."
    docker compose up -d
    
    log_success "Remnawave Panel успешно развернута!"
    echo -e "URL: ${CYAN}https://${PANEL_DOMAIN}${NC}"
    echo -e "Метрики Пароль: ${YELLOW}${METRICS_PASS}${NC}"
}

# --- Module 2: Remnawave Node ---
install_node() {
    log_info "=== Установка Remnawave Node ==="

    read -rp "Введите URL основной Панели (например, https://panel.example.com): " PANEL_URL
    read -rsp "Введите секретный токен связи (SECRET_KEY) из Панели: " SECRET_KEY
    echo

    WORK_DIR="/opt/remnawave-node"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    log_info "Создание .env..."
    cat <<EOF > .env
PANEL_URL=${PANEL_URL}
SECRET_KEY=${SECRET_KEY}
EOF

    log_info "Создание docker-compose.yml (network_mode: host)..."
    cat <<EOF > docker-compose.yml
services:
  remnawave-node:
    image: ghcr.io/remnawave/node:latest
    container_name: remnawave-node
    restart: always
    network_mode: host
    env_file: .env
EOF

    log_info "Настройка брандмауэра для входящих подключений Ноды..."
    log_info "Диапазон портов для подключения клиентов и связей нод: 9000-9200 (TCP/UDP)."
    
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        ufw allow 9000:9200/tcp
        ufw allow 9000:9200/udp
        log_success "Правила UFW обновлены для портов 9000-9200."
    fi

    log_info "Запуск Ноды..."
    docker compose up -d

    log_success "Remnawave Node успешно развернута в режиме network_mode: host!"
}

# --- Module 3: Subscription Page + Caddy ---
install_subpage() {
    log_info "=== Установка Remnawave Subscription Page + Caddy ==="

    read -rp "Введите домен для Страницы Подписок (например, sub.example.com): " SUB_DOMAIN
    read -rp "Введите Email для SSL Let's Encrypt: " SSL_EMAIL
    read -rp "Введите URL Панели Remnawave: " PANEL_URL
    read -rsp "Введите API Токен (REMNAWAVE_TOKEN): " REMNAWAVE_TOKEN
    echo

    WORK_DIR="/opt/remnawave-subpage"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    log_info "Создание .env..."
    cat <<EOF > .env
REMNAWAVE_API_URL=${PANEL_URL}
REMNAWAVE_API_TOKEN=${REMNAWAVE_TOKEN}
PORT=3000
EOF

    log_info "Создание docker-compose.yml..."
    cat <<EOF > docker-compose.yml
services:
  subscription-page:
    image: ghcr.io/remnawave/subscription-page:latest
    container_name: remnawave-subpage
    restart: always
    env_file: .env
    ports:
      - "127.0.0.1:3001:3000"

  caddy:
    image: caddy:2-alpine
    container_name: remnawave-subpage-caddy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - subscription-page

volumes:
  caddy_data:
  caddy_config:
EOF

    log_info "Создание Caddyfile..."
    cat <<EOF > Caddyfile
${SUB_DOMAIN} {
    email ${SSL_EMAIL}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    reverse_proxy 127.0.0.1:3001
}
EOF

    log_info "Запуск сервисов..."
    docker compose up -d

    log_success "Страница подписок успешно установлена!"
    echo -e "URL: ${CYAN}https://${SUB_DOMAIN}${NC}"
}

# --- Main Menu ---
show_menu() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${GREEN}      Remnawave Deployment Manager (Caddy)           ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo "1) Установить Remnawave Panel + Caddy (Панель управления)"
    echo "2) Установить Remnawave Node (Нода Xray/Sing-box)"
    echo "3) Установить Remnawave Subscription Page + Caddy (Страница подписок)"
    echo "4) Выход"
    echo -e "${CYAN}=====================================================${NC}"
    read -rp "Выберите пункт меню [1-4]: " CHOICE

    case $CHOICE in
        1)
            install_panel
            ;;
        2)
            install_node
            ;;
        3)
            install_subpage
            ;;
        4)
            log_info "Выход."
            exit 0
            ;;
        *)
            log_error "Неверный выбор. Попробуйте снова."
            sleep 2
            show_menu
            ;;
    esac
}

# --- Entry Point ---
check_root
install_dependencies
show_menu