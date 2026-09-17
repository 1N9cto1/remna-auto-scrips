# 🚀 Remnawave Automatic Deployment Manager

Интерактивный Bash-скрипт (`deploy.sh`) для автоматического разворачивания компонентов инфраструктуры **Remnawave** с использованием веб-сервера **Caddy** в качестве Reverse Proxy.

Конфигурация сервисов построена строго на основе [официальной документации Remnawave](https://docs.rw/install/remnawave-panel).

---

## ⚡ Быстрый запуск

Запустите скрипт на вашем Linux-сервере (Ubuntu/Debian/RHEL) от имени `root`:

```bash
bash <(curl -sSL [https://raw.githubusercontent.com/1N9cto1/remna-auto-scrips/main/deploy.sh](https://raw.githubusercontent.com/1N9cto1/remna-auto-scrips/main/deploy.sh))