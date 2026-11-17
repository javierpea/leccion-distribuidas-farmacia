#!/bin/bash
# =====================================================================
#  Instala / actualiza NGINX + Keepalived en la VM Ubuntu de un servidor.
#
#     cd ~/leccion-distribuidas-farmacia
#     bash keepalived/instalar_nodo.sh 1      # Server 1 (MASTER)
#     bash keepalived/instalar_nodo.sh 2      # Server 2 (ESCLAVO 1)
#     bash keepalived/instalar_nodo.sh 3      # Server 3 (ESCLAVO 2)
#
#  Se puede volver a ejecutar después de un "git pull" (por ejemplo,
#  cuando cambiaron las IPs en ips.env): recrea NGINX y reinicia Keepalived.
# =====================================================================
set -e

case "$1" in
    1) CONF="keepalived-server1-master.conf";  NODO="master" ;;
    2) CONF="keepalived-server2-backup1.conf"; NODO="esclavo1" ;;
    3) CONF="keepalived-server3-backup2.conf"; NODO="esclavo2" ;;
    *) echo "Uso: bash keepalived/instalar_nodo.sh <1|2|3>"; exit 1 ;;
esac

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"

# Paquetes (solo la primera vez)
if ! command -v docker > /dev/null || ! command -v keepalived > /dev/null; then
    sudo apt update
    sudo apt install -y docker.io docker-compose-v2 keepalived curl git
fi

echo ">> NGINX (Docker) como $NODO"
cd "$RAIZ/nginx"
# Nombre del nodo: NGINX lo envía en la cabecera X-Nodo y la app lo muestra
echo "NODO_NOMBRE=$NODO" > .env
sudo docker compose up -d --force-recreate

echo ">> Keepalived ($CONF)"
sudo cp "$RAIZ/keepalived/check_nginx.sh" /etc/keepalived/check_nginx.sh
sudo chmod 755 /etc/keepalived/check_nginx.sh
sudo cp "$RAIZ/keepalived/$CONF" /etc/keepalived/keepalived.conf
sudo systemctl enable keepalived
sudo systemctl restart keepalived

sleep 3
echo ">> Estado"
curl -fs "http://127.0.0.1:$(grep -oP '"\K[0-9]+(?=:8080")' "$RAIZ/nginx/docker-compose.yml")/health" \
    && echo "   NGINX OK" || echo "   NGINX NO responde"
VIP=$(grep -A1 'virtual_ipaddress' "/etc/keepalived/keepalived.conf" | tail -1 | awk '{print $1}' | cut -d/ -f1)
if ip -4 addr | grep -q " $VIP/"; then
    echo "   Este nodo TIENE la IP virtual $VIP (MASTER activo)"
else
    echo "   Este nodo NO tiene la IP virtual $VIP (BACKUP)"
fi
