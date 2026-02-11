#!/bin/bash

# =================================================================
# Telegram MTProxy Installer v2.1 (MTG Go + Docker)
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
OLD_SERVICE="mtproxy.service"

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
print_banner "Установка Telegram MTProxy"

# 2. Деинсталляция старой версии (нативной)
if systemctl is-active --quiet $OLD_SERVICE; then
    print_step "Обнаружена старая версия (C-proxy). Удаление..."
    systemctl stop $OLD_SERVICE &>/dev/null
    systemctl disable $OLD_SERVICE &>/dev/null
    rm -f /etc/systemd/system/$OLD_SERVICE
    rm -rf /opt/mtproxy
    rm -f /usr/local/bin/mtproxy
    echo -e "${GREEN}Старая версия удалена.${NC}"
fi

# 3. Диагностика сети (пинги как в v1.2)
print_step "Шаг 1: Диагностика сети до Telegram"
TG_IPS=("149.154.175.50" "149.154.167.51" "149.154.175.100")
for ip in "${TG_IPS[@]}"; do
    echo -n "Проверка $ip... "
    PING_RES=$(ping -c 1 -W 2 $ip 2>/dev/null | grep 'avg' | awk -F'/' '{print $5}')
    if [ ! -z "$PING_RES" ]; then echo -e "${GREEN}OK (${PING_RES} ms)${NC}"; else echo -e "${RED}FAIL${NC}"; fi
done

# 4. Установка Docker
if ! command -v docker &> /dev/null; then
    print_step "Шаг 2: Установка Docker"
    echo "Загрузка Docker..."
    curl -fsSL https://get.docker.com | sh &>/dev/null
    systemctl enable --now docker &>/dev/null
    echo -e "${GREEN}Docker успешно установлен.${NC}"
fi

# 5. Настройка параметров
print_step "Шаг 3: Настройка параметров"
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org)

read -p "Порт прокси [по умолчанию 443]: " PROXY_PORT < /dev/tty
PROXY_PORT=${PROXY_PORT:-443}

read -p "Укажите домен (для ссылок) [оставьте пустым для $SERVER_IP]: " PROXY_DOMAIN < /dev/tty
PROXY_ADDR=${PROXY_DOMAIN:-$SERVER_IP}

if [ ! -z "$PROXY_DOMAIN" ]; then
    echo -n "Проверка DNS для $PROXY_DOMAIN... "
    DOMAIN_IP=$(getent hosts "$PROXY_DOMAIN" | awk '{print $1}' | head -n 1)
    if [ "$DOMAIN_IP" == "$SERVER_IP" ]; then
        echo -e "${GREEN}OK${NC}"
    elif [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}НЕ ОПРЕДЕЛЕН${NC}"
        echo -e "${YELLOW}⚠️  ВНИМАНИЕ: Домен пока не указывает ни на какой IP. Проверьте A-запись.${NC}"
    else
        echo -e "${YELLOW}WARNING${NC}"
        echo -e "${YELLOW}⚠️  ВНИМАНИЕ: Домен указывает на $DOMAIN_IP, а IP сервера $SERVER_IP${NC}"
    fi
fi

# 6. Выбор домена маскировки (пинги как в v1.2)
print_step "Шаг 4: Настройка Fake TLS маскировки"
TLS_DOMAINS=("google.com" "facebook.com" "cloudflare.com" "microsoft.com" "apple.com" "netflix.com")
echo "Поиск лучшего домена для маскировки..."
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

# 7. Продвижение канала
print_step "Шаг 5: Настройка продвижения (AD TAG)"
echo -e "${YELLOW}Подсказка:${NC} Чтобы ваш канал отображался у пользователей прокси,"
echo -e "зарегистрируйте прокси в @MTProxybot и получите AD TAG."
echo -e "Если его нет, нажмите [ENTER] (можно добавить позже).\n"
read -p "Введите AD TAG (hex): " AD_TAG < /dev/tty

# 8. Запуск MTG
print_step "Шаг 6: Развертывание прокси (Docker)"
mkdir -p $BASE_DIR

IMAGE="9seconds/mtg:latest"
MIRRORS=("dockerhub.timeweb.cloud" "dockerhub1.beget.com" "cr.yandex/mirror")

echo "Получение образа $IMAGE..."
SUCCESS=0

# Пробуем прямой pull
if docker pull $IMAGE; then
    SUCCESS=1
else
    echo -e "${YELLOW}Прямой доступ к Docker Hub ограничен. Пробую зеркала...${NC}"
    for mirror in "${MIRRORS[@]}"; do
        echo -n "Проверка $mirror... "
        if docker pull $mirror/$IMAGE; then
            docker tag $mirror/$IMAGE $IMAGE
            echo -e "${GREEN}OK${NC}"
            SUCCESS=1
            break
        else
            echo -e "${RED}FAIL${NC}"
        fi
    done
fi

if [ $SUCCESS -eq 0 ]; then
    echo -e "${RED}❌ Ошибка: Не удалось загрузить образ Docker. Docker Hub заблокирован, и зеркала недоступны.${NC}"
    exit 1
fi

echo -n "Генерация секретного ключа... "
SECRET=$(docker run --rm $IMAGE generate-secret -c $TLS_DOMAIN 2>/dev/null | tail -n 1)
if [[ -z "$SECRET" ]]; then
    SECRET="ee$(head -c 16 /dev/urandom | xxd -ps | tr -d '\n')$(echo -n "$TLS_DOMAIN" | xxd -ps | tr -d '\n')"
fi
echo -e "${GREEN}Готово${NC}"

echo -n "Освобождение порта $PROXY_PORT... "
docker rm -f mtp_proxy &>/dev/null
fuser -k $PROXY_PORT/tcp &>/dev/null
echo -e "${GREEN}OK${NC}"

echo -n "Запуск контейнера mtp_proxy... "
TAG_ARG=""
[[ ! -z "$AD_TAG" ]] && TAG_ARG="-t $AD_TAG"

docker run -d \
  --name mtp_proxy \
  --restart always \
  -p $PROXY_PORT:3128 \
  -e SECRET="$SECRET" \
  -e TAG="$AD_TAG" \
  -e TLS_DOMAIN="$TLS_DOMAIN" \
  -e ADDR="$PROXY_ADDR" \
  -e PORT="$PROXY_PORT" \
  $IMAGE run $SECRET $TAG_ARG

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Служба запущена успешно!${NC}"
else
    echo -e "${RED}Ошибка при запуске контейнера.${NC}"
    exit 1
fi

# 9. Firewall
print_step "Шаг 7: Настройка доступа"
echo -n "Открытие порта $PROXY_PORT... "
if command -v ufw > /dev/null && systemctl is-active --quiet ufw; then ufw allow $PROXY_PORT/tcp &>/dev/null; fi
iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT 2>/dev/null
echo -e "${GREEN}OK${NC}"

# 10. Создание CLI (mtp)
print_step "Шаг 8: Глобальная команда управления"
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
    if [[ -z "$CONT" || "$CONT" == "[]" ]]; then echo -e "${RED}Контейнер mtp_proxy не найден.${NC}"; exit 1; fi
    
    SECRET=$(echo "$CONT" | grep -oP '(?<="SECRET=)[^"]+')
    TAG=$(echo "$CONT" | grep -oP '(?<="TAG=)[^"]+')
    TLS_DOM=$(echo "$CONT" | grep -oP '(?<="TLS_DOMAIN=)[^"]+')
    ADDR=$(echo "$CONT" | grep -oP '(?<="ADDR=)[^"]+')
    PORT=$(echo "$CONT" | grep -oP '(?<="PORT=)[^"]+')
    PORT=${PORT:-443}

    STATUS_TEXT="${RED}Остановлен${NC}"
    docker ps | grep -q mtp_proxy && STATUS_TEXT="${GREEN}Активен (Docker)${NC}"

    echo -e "\n${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${BOLD}${CYAN}┃                💎 TG PROXY [MTG v2.1]                       ┃${NC}"
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
    
    echo -e "\n  ${BOLD}${BLUE}Управление:${NC} mtp {status|logs|restart|domain|update|uninstall}\n"
}

case "$1" in
    logs) docker logs -f mtp_proxy ;;
    restart) docker restart mtp_proxy && echo "Служба перезапущена." ;;
    status) docker ps -f name=mtp_proxy ;;
    check)
        PORT=$(docker inspect mtp_proxy | grep -oP '(?<="PORT=)[^"]+')
        echo "Проверка порта ${PORT:-443} из интернета..."
        RES=$(curl -s --max-time 10 "http://portcheck.transmissionbt.com/${PORT:-443}")
        [[ "$RES" == "1" ]] && echo -e "${GREEN}✅ Порт открыт!${NC}" || echo -e "${RED}❌ Порт закрыт!${NC}"
        ;;
    domain)
        read -p "Новый домен маскировки (напр. apple.com): " NEW_DOM
        [[ -z "$NEW_DOM" ]] && exit 1
        C=$(docker inspect mtp_proxy)
        ADDR=$(echo "$C" | grep -oP '(?<="ADDR=)[^"]+')
        TAG=$(echo "$C" | grep -oP '(?<="TAG=)[^"]+')
        PORT=$(echo "$C" | grep -oP '(?<="PORT=)[^"]+')
        NS=$(docker run --rm 9seconds/mtg:2 generate-secret -c $NEW_DOM 2>/dev/null | tail -n 1)
        [[ -z "$NS" ]] && NS="ee$(head -c 16 /dev/urandom | xxd -ps | tr -d '\n')$(echo -n "$NEW_DOM" | xxd -ps | tr -d '\n')"
        docker rm -f mtp_proxy &>/dev/null
        T_ARG=""; [[ ! -z "$TAG" ]] && T_ARG="-t $TAG"
        docker run -d --name mtp_proxy --restart always -p ${PORT:-443}:3128 \
          -e SECRET="$NS" -e TAG="$TAG" -e TLS_DOMAIN="$NEW_DOM" -e ADDR="$ADDR" -e PORT="$PORT" \
          9seconds/mtg:2 run $NS $T_ARG &>/dev/null
        echo -e "${GREEN}Маскировка изменена на $NEW_DOM.${NC}"
        /usr/local/bin/mtp
        ;;
    update) docker pull 9seconds/mtg:2 && docker restart mtp_proxy ;;
    uninstall)
        read -p "Удалить всё? [y/N]: " conf
        [[ "$conf" =~ ^[Yy]$ ]] && { docker rm -f mtp_proxy; rm -f /usr/local/bin/mtp; rm -rf /opt/mtp; echo "Удалено."; }
        ;;
    *) show_dashboard ;;
esac
EOF
chmod +x $CLI_PATH

# 11. Финал
print_step "Шаг 9: Установка завершена успешно!"
sleep 2
mtp
