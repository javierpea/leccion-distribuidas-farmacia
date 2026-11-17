#!/bin/bash
# Usado por Keepalived en PC1 y PC2.
# Copiar a /etc/keepalived/check_nginx.sh y dar permisos:
#   sudo chmod 755 /etc/keepalived/check_nginx.sh
# Devuelve 0 si Nginx responde, 1 si no (=> la IP virtual se mueve).

if ! pidof nginx > /dev/null; then
    exit 1
fi

if ! curl -fsS --max-time 2 http://127.0.0.1/nginx-health > /dev/null; then
    exit 1
fi

exit 0
