#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SERVER_WG_NIC="wg0"
SERVER_WG_IPV4="10.10.10.1"
SERVER_WG_IPV6="fd42:42:42::1"
CLIENT_DNS_1="9.9.9.9"
CLIENT_DNS_2="8.8.8.8"
ALLOWED_IPS="0.0.0.0/0,::/0"

# ══════════════════════════════════════════════
# Проверки
# ══════════════════════════════════════════════

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Нужен root: sudo $0${NC}"
    exit 1
fi

# Определяем ОС
source /etc/os-release 2>/dev/null
OS="${ID}"

if [[ ${OS} != "debian" && ${OS} != "ubuntu" && ${OS} != "raspbian" ]]; then
    echo -e "${RED}Поддерживаются только Debian/Ubuntu${NC}"
    exit 1
fi

[[ ${OS} == "raspbian" ]] && OS="debian"

# ══════════════════════════════════════════════
# Определяем сеть
# ══════════════════════════════════════════════

detect_network() {
    SERVER_PUB_NIC=$(ip -4 route ls | grep default | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
    SERVER_PUB_IP=$(ip -4 addr show "$SERVER_PUB_NIC" | grep -oP 'inet \K[\d.]+' | head -1)
    SERVER_PUB_IPV6=$(ip -6 addr show "$SERVER_PUB_NIC" scope global | grep -oP 'inet6 \K[^/]+' | head -1)
}

# ══════════════════════════════════════════════
# Утилита: домашняя папка
# ══════════════════════════════════════════════

get_home_dir() {
    local CLIENT_NAME=$1
    if [ -e "/home/${CLIENT_NAME}" ]; then
        echo "/home/${CLIENT_NAME}"
    elif [ "${SUDO_USER}" ] && [ "${SUDO_USER}" != "root" ]; then
        echo "/home/${SUDO_USER}"
    else
        echo "/root"
    fi
}

# ══════════════════════════════════════════════
# Установка WireGuard сервера
# ══════════════════════════════════════════════

install_server() {
    detect_network

    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  WireGuard Automatic Installer v.1.2         ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Параметры:${NC}"
    echo "  Публичный IP:    $SERVER_PUB_IP"
    echo "  IPv6:            ${SERVER_PUB_IPV6:-нет}"
    echo "  Интерфейс:       $SERVER_PUB_NIC"
    echo "  WG интерфейс:    $SERVER_WG_NIC"
    echo "  Туннель IPv4:    ${SERVER_WG_IPV4}/24"
    echo "  Туннель IPv6:    ${SERVER_WG_IPV6}/64"
    echo "  DNS:             ${CLIENT_DNS_1}, ${CLIENT_DNS_2}"
    echo ""

    # Рандомный порт
    SERVER_PORT=$(shuf -i49152-65535 -n1)
    echo "  Порт:            $SERVER_PORT"
    echo ""

    # --- Установка пакетов ---
    echo -e "${YELLOW}[1/4] Установка пакетов...${NC}"
    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        wireguard \
        wireguard-tools \
        iptables \
        net-tools \
        qrencode \
        curl \
        mc \
        > /dev/null 2>&1
    echo -e "${GREEN}  ✓ Пакеты установлены${NC}"

    # Проверка
    if ! command -v wg &>/dev/null; then
        echo -e "${RED}  ✗ wg не найден! Установка не удалась.${NC}"
        exit 1
    fi

    # --- Генерация ключей ---
    echo -e "${YELLOW}[2/4] Генерация ключей...${NC}"
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    SERVER_PRIV_KEY=$(wg genkey)
    SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)
    echo -e "${GREEN}  ✓ Ключи сгенерированы${NC}"

    # --- Сохраняем параметры ---
    echo -e "${YELLOW}[3/4] Создание конфигурации...${NC}"

    cat > /etc/wireguard/params << EOF
SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}
EOF

    # --- Конфиг сервера ---
    cat > "/etc/wireguard/${SERVER_WG_NIC}.conf" << EOF
[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
EOF

    chmod 600 "/etc/wireguard/${SERVER_WG_NIC}.conf"
    echo -e "${GREEN}  ✓ Конфиг создан${NC}"

    # --- Sysctl ---
    echo -e "${YELLOW}[4/4] Запуск сервера...${NC}"

    cat > /etc/sysctl.d/wg.conf << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl --system > /dev/null 2>&1

    # Запуск
    systemctl start "wg-quick@${SERVER_WG_NIC}"
    systemctl enable "wg-quick@${SERVER_WG_NIC}" > /dev/null 2>&1

    # Проверка
    if systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"; then
        echo -e "${GREEN}  ✓ WireGuard сервер запущен!${NC}"
    else
        echo -e "${RED}  ✗ Сервер не запустился. Попробуйте перезагрузить сервер.${NC}"
    fi

    echo ""

    # Создаём первого клиента
    echo -e "${CYAN}Создание первого клиента...${NC}"
    echo ""
    add_client
}

# ══════════════════════════════════════════════
# Добавить клиента
# ══════════════════════════════════════════════

add_client() {
    echo ""
    echo -ne "${YELLOW}Имя клиента (латиница, без пробелов): ${NC}"
    read -r CLIENT_NAME

    # Валидация
    if [[ ! ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ${#CLIENT_NAME} -ge 16 ]]; then
        echo -e "${RED}Имя должно быть латиницей, цифры/дефис/подчёркивание, до 15 символов${NC}"
        return 1
    fi

    # Проверяем дубликат
    if grep -q -E "^### Client ${CLIENT_NAME}$" "/etc/wireguard/${SERVER_WG_NIC}.conf"; then
        echo -e "${RED}Клиент ${CLIENT_NAME} уже существует!${NC}"
        return 1
    fi

    # Находим свободный IP
    for DOT_IP in $(seq 2 254); do
        if ! grep -q "${SERVER_WG_IPV4%.*}.${DOT_IP}" "/etc/wireguard/${SERVER_WG_NIC}.conf"; then
            break
        fi
    done

    CLIENT_WG_IPV4="${SERVER_WG_IPV4%.*}.${DOT_IP}"
    CLIENT_WG_IPV6="${SERVER_WG_IPV6%::*}::${DOT_IP}"

    # Генерация ключей
    CLIENT_PRIV_KEY=$(wg genkey)
    CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
    CLIENT_PRE_SHARED_KEY=$(wg genpsk)

    HOME_DIR=$(get_home_dir "${CLIENT_NAME}")

    # Endpoint
    ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

    # Конфиг клиента
    cat > "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

# Uncomment the next line to set a custom MTU
# This might impact performance, so use it only if you know what you are doing
# See https://github.com/nitred/nr-wg-mtu-finder to find your optimal MTU
# MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}
EOF

    # Добавляем в серверный конфиг
    cat >> "/etc/wireguard/${SERVER_WG_NIC}.conf" << EOF

### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
EOF

    # Применяем без перезапуска
    wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

    echo ""
    echo -e "${GREEN}  ✓ Клиент ${CLIENT_NAME} создан${NC}"
    echo -e "${GREEN}  IP: ${CLIENT_WG_IPV4}${NC}"
    echo -e "${GREEN}  Конфиг: ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"
    echo ""

    # QR код
    if command -v qrencode &>/dev/null; then
        echo -e "${CYAN}QR-код для подключения:${NC}"
        echo ""
        qrencode -t ansiutf8 -l L < "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
        echo ""
    fi

    # Показываем конфиг
    echo -e "${CYAN}Конфиг клиента:${NC}"
    echo "─────────────────────────────────"
    cat "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
    echo "─────────────────────────────────"
    echo ""
}

# ══════════════════════════════════════════════
# Список клиентов
# ══════════════════════════════════════════════

list_clients() {
    echo ""
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")

    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        echo -e "${YELLOW}  Нет клиентов${NC}"
        return
    fi

    echo -e "${CYAN}  Клиенты WireGuard (${NUMBER_OF_CLIENTS}):${NC}"
    echo ""

    local i=1
    while IFS= read -r line; do
        CLIENT_NAME=$(echo "$line" | cut -d ' ' -f 3)
        # Ищем IP клиента
        CLIENT_IP=$(grep -A 3 "^### Client ${CLIENT_NAME}$" "/etc/wireguard/${SERVER_WG_NIC}.conf" | grep "AllowedIPs" | sed 's/.*= //' | cut -d'/' -f1)
        # Проверяем handshake через wg show
        LAST_HANDSHAKE=$(wg show "${SERVER_WG_NIC}" 2>/dev/null | grep -A 4 "$(grep -A 1 "^### Client ${CLIENT_NAME}$" "/etc/wireguard/${SERVER_WG_NIC}.conf" | grep PublicKey | sed 's/.*= //')" | grep "latest handshake" | sed 's/.*: //')

        if [ -n "$LAST_HANDSHAKE" ]; then
            STATUS="${GREEN}●${NC} онлайн"
        else
            STATUS="${RED}○${NC} офлайн"
        fi

        echo -e "  ${i}) ${CLIENT_NAME}  │  ${CLIENT_IP}  │  ${STATUS}"
        i=$((i + 1))
    done < <(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")

    echo ""
}

# ══════════════════════════════════════════════
# Отключить (удалить) клиента
# ══════════════════════════════════════════════

revoke_client() {
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")

    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        echo -e "${YELLOW}  Нет клиентов для отключения${NC}"
        return
    fi

    echo ""
    echo -e "${YELLOW}Выберите клиента для отключения:${NC}"
    grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
    echo ""

    echo -n "Номер клиента: "
    read -r CLIENT_NUMBER

    if [[ ! ${CLIENT_NUMBER} =~ ^[0-9]+$ ]] || [[ ${CLIENT_NUMBER} -lt 1 ]] || [[ ${CLIENT_NUMBER} -gt ${NUMBER_OF_CLIENTS} ]]; then
        echo -e "${RED}Неверный выбор${NC}"
        return
    fi

    CLIENT_NAME=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}p")

    echo ""
    echo -ne "${RED}Удалить клиента ${CLIENT_NAME}? [y/N]: ${NC}"
    read -r CONFIRM

    if [[ ${CONFIRM} != "y" && ${CONFIRM} != "Y" && ${CONFIRM} != "д" && ${CONFIRM} != "Д" ]]; then
        echo "Отменено."
        return
    fi

    # Удаляем блок [Peer] из конфига
    sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

    # Удаляем файл клиента
    HOME_DIR=$(get_home_dir "${CLIENT_NAME}")
    rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

    # Применяем
    wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

    echo -e "${GREEN}  ✓ Клиент ${CLIENT_NAME} удалён${NC}"
}

# ══════════════════════════════════════════════
# Удалить WireGuard сервер
# ══════════════════════════════════════════════

uninstall_server() {
    echo ""
    echo -e "${RED}  ВНИМАНИЕ: Это полностью удалит WireGuard и все конфиги!${NC}"
    echo ""
    echo -ne "${YELLOW}Вы уверены? [y/N]: ${NC}"
    read -r CONFIRM

    if [[ ${CONFIRM} != "y" && ${CONFIRM} != "Y" && ${CONFIRM} != "д" && ${CONFIRM} != "Д" ]]; then
        echo "Отменено."
        return
    fi

    systemctl stop "wg-quick@${SERVER_WG_NIC}" 2>/dev/null
    systemctl disable "wg-quick@${SERVER_WG_NIC}" 2>/dev/null

    apt-get remove -y wireguard wireguard-tools qrencode > /dev/null 2>&1

    rm -rf /etc/wireguard
    rm -f /etc/sysctl.d/wg.conf
    sysctl --system > /dev/null 2>&1

    # Удаляем клиентские конфиги
    rm -f /root/${SERVER_WG_NIC}-client-*.conf
    rm -f /home/*/${SERVER_WG_NIC}-client-*.conf 2>/dev/null

    echo -e "${GREEN}  ✓ WireGuard полностью удалён${NC}"
}

# ══════════════════════════════════════════════
# Статус сервера
# ══════════════════════════════════════════════

show_server_status() {
    echo ""
    echo -e "${CYAN}═══ Статус WireGuard сервера ═══${NC}"
    echo ""
    echo "  Интерфейс:   ${SERVER_WG_NIC}"
    echo "  Порт:        ${SERVER_PORT}"
    echo "  Публичный IP: ${SERVER_PUB_IP}"
    echo "  Туннель:     ${SERVER_WG_IPV4}/24, ${SERVER_WG_IPV6}/64"
    echo ""
    wg show "${SERVER_WG_NIC}" 2>/dev/null || echo -e "${RED}  Сервер не запущен${NC}"
    echo ""
}

# ══════════════════════════════════════════════
# МЕНЮ УПРАВЛЕНИЯ
# ══════════════════════════════════════════════

manage_menu() {
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  WireGuard Сервер — Управление               ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo ""

    show_server_status
    list_clients

    echo -e "${CYAN}Что сделать?${NC}"
    echo ""
    echo "  1) Список клиентов"
    echo "  2) Добавить нового клиента"
    echo "  3) Отключить (удалить) клиента"
    echo "  4) Удалить WireGuard сервер"
    echo "  0) Выход"
    echo ""
    echo -n "Выбор [0-4]: "
    read -r MENU_OPTION

    case "${MENU_OPTION}" in
        1) list_clients ;;
        2) add_client ;;
        3) revoke_client ;;
        4) uninstall_server ;;
        0|"") echo "Выход." ;;
        *) echo -e "${RED}Неверный выбор${NC}" ;;
    esac
}

# ══════════════════════════════════════════════
# ГЛАВНАЯ ЛОГИКА
# ══════════════════════════════════════════════

if [[ -e /etc/wireguard/params ]]; then
    source /etc/wireguard/params
    manage_menu
else
    install_server
fi
