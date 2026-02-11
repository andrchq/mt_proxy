#!/bin/bash

# =================================================================
# Telegram MTProxy Installer v2.0 (MTG Go Edition)
# =================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Пути
BASE_DIR="/opt/mtp"
CLI_PATH="/usr/local/bin/mtp"
OLD_SERVICE="mtproxy.service"

# Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен быть запущен от имени root${NC}"
   exit 1
fi

print_banner() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BOLD}${CYAN}   $1 ${NC}"
    echo -e "${BLUE}================================================================${NC}\n"
}

print_step() {
    echo -e "${BOLD}${PURPLE}➤ $1${NC}"
    echo -e "${PURPLE}----------------------------------------------------------------${NC}"
}

# 1. Деинсталляция старой версии
clear
print_banner "Установка Telegram MTProxy (Ядро: MTG v2)"

if systemctl is-active --quiet $OLD_SERVICE; then
    print_step "Обнаружена старая версия. Удаление..."
    systemctl stop $OLD_SERVICE &>/dev/null
    systemctl disable $OLD_SERVICE &>/dev/null
    rm -f /etc/systemd/system/$OLD_SERVICE
    rm -rf /opt/mtproxy
    rm -f /usr/local/bin/mtproxy
    echo -e "${GREEN}Старая версия удалена.${NC}"
fi

# 2. Установка Docker
if ! command -v docker &> /dev/null; then
    print_step "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    echo -e "${GREEN}Docker установлен.${NC}"
fi

# 3. Настройка параметров
print_step "Настройка параметров"
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org)

read -p "Укажите домен (для DNS прокси) [оставьте пустым для $SERVER_IP]: " PROXY_DOMAIN < /dev/tty
PROXY_ADDR=${PROXY_DOMAIN:-$SERVER_IP}

# Проверка DNS если домен указан
if [ ! -z "$PROXY_DOMAIN" ]; then
    echo -e "Проверка DNS для $PROXY_DOMAIN..."
    DOMAIN_IP=$(getent hosts "$PROXY_DOMAIN" | awk '{print $1}' | head -n 1)
    if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
        echo -e "${RED}⚠️  ВНИМАНИЕ: Домен указывает на $DOMAIN_IP, а IP сервера $SERVER_IP${NC}"
        read -p "Продолжить? [y/N]: " choice < /dev/tty
        [[ "$choice" =~ ^[Yy]$ ]] || exit 1
    fi
fi

# 4. Выбор домена маскировки (Fake TLS)
print_step "Выбор домена маскировки"
TLS_DOMAINS=("google.com" "facebook.com" "cloudflare.com" "microsoft.com" "apple.com" "amazon.com" "wikipedia.org" "bing.com" "reddit.com" "stackoverflow.com" "github.com" "netflix.com")
echo "Поиск лучшего домена..."

BEST_DOMAIN="google.com"
MIN_PING=999

for domain in "${TLS_DOMAINS[@]}"; do
    PING_TIME=$(ping -c 1 -W 1 $domain 2>/dev/null | grep 'avg' | awk -F'/' '{print $5}')
    if [ ! -z "$PING_TIME" ]; then
        if (( $(echo "$PING_TIME < $MIN_PING" | bc -l 2>/dev/null || echo 0) )); then
            MIN_PING=$PING_TIME
            BEST_DOMAIN=$domain
        fi
    fi
done

read -p "Домен для маскировки [по умолчанию $BEST_DOMAIN]: " TLS_DOMAIN < /dev/tty
TLS_DOMAIN=${TLS_DOMAIN:-$BEST_DOMAIN}

# 5. Продвижение канала
read -p "AD TAG (hex) [оставьте пустым для настройки позже]: " AD_TAG < /dev/tty

# 6. Запуск MTG в Docker
print_step "Запуск прокси..."
mkdir -p $BASE_DIR

# Генерация секрета через временный контейнер mtg
SECRET=$(docker run --rm nopeslide/mtg generate-secret -c $TLS_DOMAIN | head -n 1)

# Остановка старого контейнера если есть
docker rm -f mtp_proxy &>/dev/null

TAG_ARG=""
[[ ! -z "$AD_TAG" ]] && TAG_ARG="-t $AD_TAG"

docker run -d \
  --name mtp_proxy \
  --restart always \
  -p 443:3128 \
  -e SECRET="$SECRET" \
  -e TAG="$AD_TAG" \
  -e TLS_DOMAIN="$TLS_DOMAIN" \
  -e ADDR="$PROXY_ADDR" \
  nopeslide/mtg run $SECRET $TAG_ARG

# 7. Создание CLI (mtp)
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
    [[ -z "$CONT" ]] && { echo "Прокси не запущен."; exit 1; }
    
    SECRET=$(echo "$CONT" | grep -oP '(?<="SECRET=)[^"]+')
    TAG=$(echo "$CONT" | grep -oP '(?<="TAG=)[^"]+')
    TLS_DOM=$(echo "$CONT" | grep -oP '(?<="TLS_DOMAIN=)[^"]+')
    ADDR=$(echo "$CONT" | grep -oP '(?<="ADDR=)[^"]+')
    
    STATUS_TEXT="${RED}Остановлен${NC}"
    docker ps | grep -q mtp_proxy && STATUS_TEXT="${GREEN}Активен (Docker)${NC}"

    echo -e "\n${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${BOLD}${CYAN}┃                💎 TG PROXY [MTG v2]                         ┃${NC}"
    echo -e "${BOLD}${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo -e "  Статус: $STATUS_TEXT"
    echo -e "  Адрес:  ${YELLOW}$ADDR${NC}:${YELLOW}443${NC}"
    echo -e "  Маскировка: ${BLUE}$TLS_DOM${NC}"
    echo -e "  AD TAG: ${PURPLE}${TAG:-"(не задан)"}${NC}"
    
    echo -e "\n  ${BOLD}${CYAN}[APP] ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    echo -e "  🔹 TLS: ${BLUE}tg://proxy?server=$ADDR&port=443&secret=$SECRET${NC}"
    
    echo -e "\n  ${BOLD}${CYAN}[WEB] ВЕБ-ССЫЛКА${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    echo -e "  🔸 Ссылка: ${BLUE}https://t.me/proxy?server=$ADDR&port=443&secret=$SECRET${NC}"
    
    echo -e "\n  ${BOLD}${BLUE}Управление:${NC} mtp {status|logs|restart|domain|update|uninstall}\n"
}

case "$1" in
    logs) docker logs -f mtp_proxy ;;
    restart) docker restart mtp_proxy && echo "Контейнер перезапущен." ;;
    status) docker stats --no-stream mtp_proxy ;;
    check)
        echo "Проверка доступности порта 443..."
        RES=$(curl -s --max-time 10 "http://portcheck.transmissionbt.com/443")
        [[ "$RES" == "1" ]] && echo -e "${GREEN}✅ Порт открыт!${NC}" || echo -e "${RED}❌ Порт закрыт!${NC}"
        ;;
    domain)
        read -p "Введите новый домен для маскировки (напр. microsoft.com): " NEW_DOM
        [[ -z "$NEW_DOM" ]] && exit 1
        # Получаем текущие данные
        OLD_CONT=$(docker inspect mtp_proxy)
        ADDR=$(echo "$OLD_CONT" | grep -oP '(?<="ADDR=)[^"]+')
        TAG=$(echo "$OLD_CONT" | grep -oP '(?<="TAG=)[^"]+')
        # Генерим новый секрет
        NEW_SECRET=$(docker run --rm nopeslide/mtg generate-secret -c $NEW_DOM | head -n 1)
        # Перезапуск
        TAG_ARG=""
        [[ ! -z "$TAG" ]] && TAG_ARG="-t $TAG"
        docker rm -f mtp_proxy &>/dev/null
        docker run -d --name mtp_proxy --restart always -p 443:3128 \
          -e SECRET="$NEW_SECRET" -e TAG="$TAG" -e TLS_DOMAIN="$NEW_DOM" -e ADDR="$ADDR" \
          nopeslide/mtg run $NEW_SECRET $TAG_ARG
        echo -e "${GREEN}Домен изменен на $NEW_DOM. Новый секрет сгенерирован.${NC}"
        /usr/local/bin/mtp
        ;;
    update)
        docker pull nopeslide/mtg
        $0 restart
        ;;
    uninstall)
        read -p "Удалить всё? [y/N]: " conf
        [[ "$conf" =~ ^[Yy]$ ]] && { docker rm -f mtp_proxy; rm -f /usr/local/bin/mtp; rm -rf /opt/mtp; echo "Удалено."; }
        ;;
    *) show_dashboard ;;
esac
EOF
chmod +x $CLI_PATH

# 8. Финал
print_step "Установка завершена!"
sleep 2
mtp
