#!/bin/bash

# =================================================================
# Telegram MTProxy Installer v3.0 (alexbers/mtprotoproxy + Docker)
# =================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Пути
BASE_DIR="/opt/mtp"
CLI_PATH="/usr/local/bin/mtp"
REPO_URL="https://github.com/alexbers/mtprotoproxy.git"

# Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен быть запущен от имени root (через sudo)${NC}"
   exit 1
fi

print_banner() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BOLD}${CYAN}   $1 ${NC}"
    echo -e "${BLUE}================================================================${NC}\n"
}

print_step() {
    echo -e "\n${BOLD}${PURPLE}➤ $1${NC}"
    echo -e "${PURPLE}----------------------------------------------------------------${NC}"
}

# 1. Приветствие и очистка
clear
print_banner "Установка Telegram MTProxy (Professional v3.0)"

# 2. Очистка старых версий
print_step "Шаг 1: Подготовка сервера"
echo -n "Удаление старых версий и конфликтных служб... "
systemctl stop mtproxy.service &>/dev/null
systemctl disable mtproxy.service &>/dev/null
docker rm -f mtp_proxy &>/dev/null
docker rm -f mtp_test &>/dev/null
echo -e "${GREEN}OK${NC}"

# 3. Диагностика сети
print_step "Шаг 2: Диагностика сети до Telegram"
TG_IPS=("149.154.175.50" "149.154.167.51" "149.154.175.100")
for ip in "${TG_IPS[@]}"; do
    echo -n "Проверка $ip... "
    PING_RES=$(ping -c 1 -W 2 $ip 2>/dev/null | grep 'avg' | awk -F'/' '{print $5}')
    if [ ! -z "$PING_RES" ]; then echo -e "${GREEN}OK (${PING_RES} ms)${NC}"; else echo -e "${RED}FAIL${NC}"; fi
done

# 4. Установка Docker и зависимостей
if ! command -v docker &> /dev/null || ! command -v git &> /dev/null; then
    print_step "Шаг 3: Установка компонентов (Docker, Git)"
    apt-get update -y &>/dev/null
    apt-get install -y git curl bc python3-pip &>/dev/null
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | sh &>/dev/null
        systemctl enable --now docker &>/dev/null
    fi
    echo -e "${GREEN}Компоненты установлены.${NC}"
fi

# 5. Настройка параметров
print_step "Шаг 4: Настройка параметров"
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org)

read -p "Порт прокси [по умолчанию 443]: " PROXY_PORT < /dev/tty
PROXY_PORT=${PROXY_PORT:-443}

read -p "Укажите домен (для ссылок) [оставьте пустым для $SERVER_IP]: " PROXY_DOMAIN < /dev/tty
PROXY_ADDR=${PROXY_DOMAIN:-$SERVER_IP}

if [ ! -z "$PROXY_DOMAIN" ]; then
    echo -n "Проверка DNS для $PROXY_DOMAIN... "
    DOMAIN_IP=$(getent hosts "$PROXY_DOMAIN" | awk '{print $1}' | head -n 1)
    if [ "$DOMAIN_IP" == "$SERVER_IP" ]; then echo -e "${GREEN}OK${NC}"; else echo -e "${YELLOW}WARNING (IP не совпал)${NC}"; fi
fi

# 6. Выбор домена маскировки
print_step "Шаг 5: Настройка Fake TLS маскировки"
TLS_DOMAINS=("google.com" "facebook.com" "cloudflare.com" "microsoft.com" "apple.com" "netflix.com")
echo "Поиск лучшего домена..."
BEST_DOMAIN="google.com"
MIN_PING=999
for domain in "${TLS_DOMAINS[@]}"; do
    echo -n "Тест $domain... "
    T=$(ping -c 1 -W 1 $domain 2>/dev/null | grep 'avg' | awk -F'/' '{print $5}')
    if [ ! -z "$T" ]; then 
        echo -e "${GREEN}${T} ms${NC}"
        if (( $(echo "$T < $MIN_PING" | bc -l 2>/dev/null || echo 0) )); then MIN_PING=$T; BEST_DOMAIN=$domain; fi
    else echo -e "${RED}FAIL${NC}"; fi
done

read -p "Домен маскировки [по умолчанию $BEST_DOMAIN]: " TLS_DOMAIN < /dev/tty
TLS_DOMAIN=${TLS_DOMAIN:-$BEST_DOMAIN}

# 7. Настройка AD TAG
print_step "Шаг 6: Настройка продвижения (AD TAG)"
echo -e "${YELLOW}Подсказка:${NC} Чтобы ваш канал отображался у пользователей,"
echo -e "зарегистрируйте прокси в @MTProxybot и получите AD TAG."
read -p "Введите AD TAG (hex) [пусто для пропуска]: " AD_TAG < /dev/tty

# 8. Клонирование и сборка
print_step "Шаг 7: Локальная сборка образа (bypass Docker Hub)"
rm -rf $BASE_DIR && mkdir -p $BASE_DIR
echo -n "Клонирование репозитория alexbers/mtprotoproxy... "
git clone --quiet $REPO_URL $BASE_DIR
echo -e "${GREEN}OK${NC}"

cd $BASE_DIR

# Генерация секрета
echo -n "Генерация секретного ключа... "
SECRET=$(head -c 16 /dev/urandom | xxd -ps | tr -d '\n')
SECRET="ee${SECRET}$(echo -n "$TLS_DOMAIN" | xxd -ps | tr -d '\n')"
echo -e "${GREEN}Готово${NC}"

# Создание Dockerfile (используем зеркала для базового образа)
cat <<EOF > Dockerfile
FROM python:3.9-slim
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir cryptography
EXPOSE 3128
CMD ["python3", "mtprotoproxy.py"]
EOF

# Создание конфига
cat <<EOF > config.py
PORT = 3128
USERS = {
    "tg": "$SECRET"
}
AD_TAG = "${AD_TAG:-""}"
TLS_DOMAIN = "$TLS_DOMAIN"
EOF

echo "Сборка Docker-образа (может занять 1-2 минуты)..."
# Добавляем --build-arg если нужны зеркала, но обычно slim тянется нормально
docker build -t mtp-custom . &>/dev/null
echo -e "${GREEN}Образ собран локально!${NC}"

# 9. Запуск
print_step "Шаг 8: Запуск прокси"
echo -n "Освобождение порта $PROXY_PORT... "
fuser -k $PROXY_PORT/tcp &>/dev/null
echo -e "${GREEN}OK${NC}"

docker run -d \
  --name mtp_proxy \
  --restart always \
  -p $PROXY_PORT:3128 \
  -v $BASE_DIR/config.py:/app/config.py:ro \
  -e ADDR="$PROXY_ADDR" \
  -e PORT="$PROXY_PORT" \
  -e SECRET="$SECRET" \
  -e TLS_DOMAIN="$TLS_DOMAIN" \
  -e TAG="$AD_TAG" \
  mtp-custom &>/dev/null

echo -e "${GREEN}Служба запущена в Docker!${NC}"

# 10. Firewall
echo -n "Настройка Firewall... "
if command -v ufw > /dev/null && systemctl is-active --quiet ufw; then ufw allow $PROXY_PORT/tcp &>/dev/null; fi
iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT 2>/dev/null
echo -e "${GREEN}OK${NC}"

# 11. Создание CLI (mtp)
cat <<'EOF' > $CLI_PATH
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

show_dashboard() {
    CONT=$(docker inspect mtp_proxy 2>/dev/null)
    if [[ -z "$CONT" || "$CONT" == "[]" ]]; then echo -e "${RED}Контейнер не найден.${NC}"; exit 1; fi
    
    SECRET=$(echo "$CONT" | grep -oP '(?<="SECRET=)[^"]+')
    TAG=$(echo "$CONT" | grep -oP '(?<="TAG=)[^"]+')
    TLS_DOM=$(echo "$CONT" | grep -oP '(?<="TLS_DOMAIN=)[^"]+')
    ADDR=$(echo "$CONT" | grep -oP '(?<="ADDR=)[^"]+')
    PORT=$(echo "$CONT" | grep -oP '(?<="PORT=)[^"]+')

    STATUS_TEXT="${RED}Остановлен${NC}"
    docker ps | grep -q mtp_proxy && STATUS_TEXT="${GREEN}Активен (v3.0 alexbers)${NC}"

    echo -e "\n${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${BOLD}${CYAN}┃                💎 TG PROXY [Professional v3.0]              ┃${NC}"
    echo -e "${BOLD}${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo -e "  Статус: $STATUS_TEXT"
    echo -e "  Адрес:  ${YELLOW}$ADDR${NC}:${YELLOW}$PORT${NC}"
    echo -e "  Маскировка: ${BLUE}$TLS_DOM${NC}"
    echo -e "  AD TAG: ${PURPLE}${TAG:-"(не задан)"}${NC}"
    
    echo -e "\n  ${BOLD}${CYAN}[APP] ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    echo -e "  🔹 TLS: ${BLUE}tg://proxy?server=$ADDR&port=$PORT&secret=$SECRET${NC}"
    
    echo -e "\n  ${BOLD}${CYAN}[WEB] ВЕБ-ССЫЛКА${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    echo -e "  🔸 Ссылка: ${BLUE}https://t.me/proxy?server=$ADDR&port=$PORT&secret=$SECRET${NC}"
    
    echo -e "\n  ${BOLD}${BLUE}Управление:${NC} mtp {status|logs|restart|domain|uninstall}\n"
}

case "$1" in
    logs) docker logs -f mtp_proxy ;;
    restart) docker restart mtp_proxy && echo "Перезапущено." ;;
    status) docker ps -f name=mtp_proxy ;;
    domain)
        read -p "Новый домен маскировки (напр. apple.com): " NEW_DOM
        [[ -z "$NEW_DOM" ]] && exit 1
        C=$(docker inspect mtp_proxy)
        ADDR=$(echo "$C" | grep -oP '(?<="ADDR=)[^"]+')
        TAG=$(echo "$C" | grep -oP '(?<="TAG=)[^"]+')
        PORT=$(echo "$C" | grep -oP '(?<="PORT=)[^"]+')
        NS="ee$(head -c 16 /dev/urandom | xxd -ps | tr -d '\n')$(echo -n "$NEW_DOM" | xxd -ps | tr -d '\n')"
        
        # Обновляем конфиг
        cat <<ECONTF > /opt/mtp/config.py
PORT = 3128
USERS = {"tg": "$NS"}
AD_TAG = "$TAG"
TLS_DOMAIN = "$NEW_DOM"
ECONTF
        
        docker restart mtp_proxy &>/dev/null
        # Обновляем ENV для dashboard
        docker rm -f mtp_proxy &>/dev/null
        docker run -d --name mtp_proxy --restart always -p $PORT:3128 -v /opt/mtp/config.py:/app/config.py:ro \
          -e ADDR="$ADDR" -e PORT="$PROXY_PORT" -e SECRET="$NS" -e TLS_DOMAIN="$NEW_DOM" -e TAG="$TAG" mtp-custom &>/dev/null
        
        echo -e "${GREEN}Маскировка изменена на $NEW_DOM.${NC}"
        /usr/local/bin/mtp
        ;;
    uninstall)
        read -p "Удалить всё? [y/N]: " conf
        [[ "$conf" =~ ^[Yy]$ ]] && { docker rm -f mtp_proxy; rm -f /usr/local/bin/mtp; rm -rf /opt/mtp; docker rmi mtp-custom; echo "Удалено."; }
        ;;
    *) show_dashboard ;;
esac
EOF
chmod +x $CLI_PATH

# 12. Финал
print_step "Шаг 9: Установка завершена!"
sleep 2
mtp
