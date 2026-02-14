#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WG_IF="wg0"
WG_CONF="/etc/wireguard/${WG_IF}.conf"

echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  WireGuard Outbound Tunnel for Amnezia Host  ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Нужен root: sudo $0${NC}"
    exit 1
fi

# ══════════════════════════════════════════════
# Функции
# ══════════════════════════════════════════════

get_network_env() {
    DEFAULT_IF=$(ip -4 route show default | grep -v "wg\|tun" | awk '{print $5}' | head -1)
    DEFAULT_GW=$(ip -4 route show default | grep -v "wg\|tun" | awk '{print $3}' | head -1)
    if [ -z "$DEFAULT_IF" ] || [ "$DEFAULT_IF" = "$WG_IF" ]; then
        DEFAULT_IF=$(ip -4 addr show | grep 'state UP' | grep -v "docker\|veth\|wg\|amn\|tun\|lo\|br-" | head -1 | awk -F: '{print $2}' | tr -d ' ')
        HOST_IP=$(ip -4 addr show "$DEFAULT_IF" | grep -oP 'inet \K[\d.]+' | head -1)
        DEFAULT_GW=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.1/')
    fi
    HOST_IP=$(ip -4 addr show "$DEFAULT_IF" | grep -oP 'inet \K[\d.]+' | head -1)
    SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
    SSH_PORT=${SSH_PORT:-22}
}

show_status() {
    echo -e "${CYAN}═══ Статус туннеля ${WG_IF} ═══${NC}"
    echo ""
    wg show "$WG_IF"
    echo ""
    echo "  Default route: $(ip route show default | head -1)"
    echo ""
    echo -n "  Внешний IP: "
    EXT_IP=$(curl -s --max-time 5 eth0.me 2>/dev/null || curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "не определён")
    echo -e "${GREEN}${EXT_IP}${NC}"
    echo ""
}

stop_tunnel() {
    echo -e "${YELLOW}Останавливаю туннель...${NC}"
    ip route replace default via "$DEFAULT_GW" dev "$DEFAULT_IF" 2>/dev/null || true
    wg-quick down "$WG_IF" 2>/dev/null || true
    iptables -t mangle -F OUTPUT 2>/dev/null || true
    ip rule del fwmark 0x1 table 100 2>/dev/null || true
    ip route flush table 100 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$WG_IF" -j MASQUERADE 2>/dev/null || true
    if [ -f /etc/resolv.conf.wg-backup ]; then
        cp /etc/resolv.conf.wg-backup /etc/resolv.conf
    fi
    sleep 1
    echo -e "${GREEN}  ✓ Туннель остановлен${NC}"
}

remove_client() {
    stop_tunnel
    systemctl disable wg-quick@${WG_IF} 2>/dev/null || true
    rm -f "$WG_CONF" /etc/resolv.conf.wg-backup
    echo -e "${GREEN}  ✓ Конфиг удалён, автозапуск отключен${NC}"
}

apply_routes() {
    cp /etc/resolv.conf /etc/resolv.conf.wg-backup 2>/dev/null || true
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9" > /etc/resolv.conf
    iptables -t mangle -A OUTPUT -p tcp --sport "$SSH_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j MARK --set-mark 0x1
    iptables -t mangle -A OUTPUT -p tcp --sport 443 -m conntrack --ctstate ESTABLISHED,RELATED -j MARK --set-mark 0x1
    iptables -t mangle -A OUTPUT -p udp --sport 443 -m conntrack --ctstate ESTABLISHED,RELATED -j MARK --set-mark 0x1
    ip route add default via "$DEFAULT_GW" dev "$DEFAULT_IF" table 100 2>/dev/null || true
    ip rule add fwmark 0x1 table 100 priority 100 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$WG_IF" -j MASQUERADE
    ip route replace default dev "$WG_IF"
}

wait_handshake() {
    echo -ne "${YELLOW}  Жду handshake"
    HANDSHAKE_OK=false
    for i in $(seq 1 15); do
        if wg show "$WG_IF" | grep -q "latest handshake"; then
            HANDSHAKE_OK=true
            break
        fi
        echo -n "."
        sleep 1
    done
    echo -e "${NC}"
    if [ "$HANDSHAKE_OK" = true ]; then
        echo -e "${GREEN}  ✓ Handshake OK!${NC}"
        return 0
    else
        echo -e "${RED}  ✗ Handshake не прошёл за 15 сек. SSH работает. Маршруты не тронуты.${NC}"
        wg show "$WG_IF"
        return 1
    fi
}

check_ip() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo -e "${CYAN}  Проверка внешнего IP                 ${NC}"
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo ""
    echo -e "  IP сервера (реальный):  ${RED}${HOST_IP}${NC}"
    echo -n "  IP сервера (текущий):   "
    NEW_IP=$(curl -s --max-time 10 eth0.me 2>/dev/null || curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "timeout")
    echo -e "${GREEN}${NEW_IP}${NC}"
    echo ""
    if [ "$NEW_IP" != "$HOST_IP" ] && [ "$NEW_IP" != "timeout" ]; then
        echo -e "${GREEN}  ✓ Трафик идёт через VPN!${NC}"
    else
        echo -e "${RED}  ✗ IP не изменился! Откатываю...${NC}"
        ip route replace default via "$DEFAULT_GW" dev "$DEFAULT_IF" 2>/dev/null
        echo -e "${YELLOW}    Default route восстановлен. SSH работает.${NC}"
    fi
}

start_tunnel() {
    wg-quick up "$WG_IF"
    if ! wg show "$WG_IF" &>/dev/null; then
        echo -e "${RED}  ✗ Не поднялся!${NC}"
        return 1
    fi
    echo -e "${GREEN}  ✓ Интерфейс поднят${NC}"
    if wait_handshake; then
        echo -e "${YELLOW}  Переключаю маршруты и DNS...${NC}"
        apply_routes
        echo -e "${GREEN}  ✓ Готово${NC}"
        check_ip
        return 0
    fi
    return 1
}

build_config() {
    local TMPRAW="$1"
    local REMOTE_WG_IP="$2"

    # Читаем сырой конфиг построчно, фильтруем лишнее
    # НЕ парсим отдельные поля — оставляем как есть
    local IN_INTERFACE=false
    local WROTE_TABLE=false
    local WROTE_POSTUP=false

    > "$WG_CONF"

    while IFS= read -r line || [ -n "$line" ]; do
        # Убираем \r и ведущие/trailing пробелы
        line=$(echo "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Пропускаем комментарии
        [[ "$line" =~ ^# ]] && continue

        # Пропускаем пустые строки подряд
        [ -z "$line" ] && continue

        # Пропускаем DNS, PostUp, PostDown, Table, SaveConfig
        echo "$line" | grep -qi "^DNS" && continue
        echo "$line" | grep -qi "^PostUp" && continue
        echo "$line" | grep -qi "^PostDown" && continue
        echo "$line" | grep -qi "^Table" && continue
        echo "$line" | grep -qi "^SaveConfig" && continue

        # Заменяем AllowedIPs
        if echo "$line" | grep -qi "^AllowedIPs"; then
            echo "AllowedIPs = 0.0.0.0/0, ::/0" >> "$WG_CONF"
            continue
        fi

        # После [Interface] добавляем Table = off
        if [ "$line" = "[Interface]" ]; then
            echo "$line" >> "$WG_CONF"
            echo "Table = off" >> "$WG_CONF"
            continue
        fi

        # Перед [Peer] добавляем PostUp/PostDown
        if [ "$line" = "[Peer]" ]; then
            echo "" >> "$WG_CONF"
            echo "PostUp = ip route replace ${REMOTE_WG_IP}/32 via ${DEFAULT_GW} dev ${DEFAULT_IF} || true" >> "$WG_CONF"
            echo "PostDown = ip route replace default via ${DEFAULT_GW} dev ${DEFAULT_IF} || true; ip route del ${REMOTE_WG_IP}/32 via ${DEFAULT_GW} dev ${DEFAULT_IF} || true; cp /etc/resolv.conf.wg-backup /etc/resolv.conf || true" >> "$WG_CONF"
            echo "" >> "$WG_CONF"
            echo "$line" >> "$WG_CONF"
            continue
        fi

        # Всё остальное — пишем как есть
        echo "$line" >> "$WG_CONF"

    done < "$TMPRAW"

    # PersistentKeepalive в конец
    echo "PersistentKeepalive = 25" >> "$WG_CONF"

    chmod 600 "$WG_CONF"
}

install_and_start() {
    get_network_env

    echo -e "${YELLOW}Окружение:${NC}"
    echo "  Интерфейс:     $DEFAULT_IF"
    echo "  IP хоста:       $HOST_IP"
    echo "  Шлюз:           $DEFAULT_GW"
    echo "  SSH порт:       $SSH_PORT"
    echo ""

    if [ -z "$DEFAULT_IF" ] || [ -z "$DEFAULT_GW" ] || [ -z "$HOST_IP" ]; then
        echo -e "${RED}Не удалось определить сеть!${NC}"
        exit 1
    fi

    echo -e "${YELLOW}[1/4] Установка пакетов...${NC}"
    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        wireguard-tools \
        iptables \
        net-tools \
        curl \
        mc \
        > /dev/null 2>&1
    modprobe wireguard 2>/dev/null || true
    echo -e "${GREEN}  ✓ wireguard-tools iptables net-tools curl mc — установлены${NC}"

    if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
        echo -e "${YELLOW}  DNS не настроен — фиксю...${NC}"
        echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9" > /etc/resolv.conf
        echo -e "${GREEN}  ✓ DNS настроен${NC}"
    fi

    echo ""
    echo -e "${YELLOW}[2/4] Вставьте WireGuard-конфиг → Enter → Ctrl+D:${NC}"
    echo ""

    TMPRAW=$(mktemp)
    cat > "$TMPRAW"

    if [ ! -s "$TMPRAW" ]; then
        echo -e "${RED}Пусто. Выход.${NC}"
        rm -f "$TMPRAW"
        exit 1
    fi

    echo -e "${GREEN}  ✓ Конфиг получен${NC}"

    echo -e "${YELLOW}[3/4] Сборка конфига...${NC}"

    REMOTE_WG_IP=$(cat "$TMPRAW" | tr -d '\r' | grep -i "Endpoint" | head -1 | sed 's/.*=[ ]*//' | sed 's/:.*//' | tr -d ' ')

    if [ -z "$REMOTE_WG_IP" ]; then
        echo -e "${RED}Не найден Endpoint!${NC}"
        cat "$TMPRAW"
        rm -f "$TMPRAW"
        exit 1
    fi

    echo -e "${GREEN}  ✓ Remote WG: ${REMOTE_WG_IP}${NC}"

    build_config "$TMPRAW" "$REMOTE_WG_IP"
    rm -f "$TMPRAW"

    echo ""
    echo -e "${GREEN}  ✓ Финальный конфиг:${NC}"
    echo ""
    cat "$WG_CONF"
    echo ""

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    echo -e "${YELLOW}[4/4] Поднимаю туннель...${NC}"
    start_tunnel

    systemctl enable wg-quick@${WG_IF} 2>/dev/null || true
}

# ══════════════════════════════════════════════
# ГЛАВНАЯ ЛОГИКА
# ══════════════════════════════════════════════

get_network_env

if ip link show "$WG_IF" &>/dev/null 2>&1; then
    echo -e "${GREEN}Туннель ${WG_IF} активен${NC}"
    echo ""
    show_status

    echo -e "${CYAN}Что сделать?${NC}"
    echo ""
    echo "  1) Показать статус"
    echo "  2) Выключить туннель"
    echo "  3) Перезапустить туннель"
    echo "  4) Заменить конфиг VPN"
    echo "  5) Удалить клиент полностью"
    echo "  0) Выход"
    echo ""
    echo -n "Выбор [0-5]: "
    read -r CHOICE

    case "$CHOICE" in
        1) show_status ;;
        2) stop_tunnel ;;
        3)
            stop_tunnel
            sleep 1
            get_network_env
            start_tunnel
            ;;
        4)
            stop_tunnel
            rm -f "$WG_CONF"
            install_and_start
            ;;
        5) remove_client ;;
        0|"") echo "Выход." ;;
        *) echo -e "${RED}Неверный выбор${NC}" ;;
    esac
elif [ -f "$WG_CONF" ]; then
    echo -e "${YELLOW}Туннель не активен, конфиг существует${NC}"
    echo ""
    echo "  1) Запустить туннель"
    echo "  2) Заменить конфиг и запустить"
    echo "  3) Удалить клиент"
    echo "  0) Выход"
    echo ""
    echo -n "Выбор [0-3]: "
    read -r CHOICE

    case "$CHOICE" in
        1) start_tunnel ;;
        2) rm -f "$WG_CONF"; install_and_start ;;
        3) remove_client ;;
        0|"") echo "Выход." ;;
    esac
else
    install_and_start
fi

echo ""
echo -e "${CYAN}Управление: bash $0${NC}"
