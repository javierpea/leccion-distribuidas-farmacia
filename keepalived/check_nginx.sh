#!/bin/bash
# Verificar que NGINX responde (Unidad 2 - Keepalived)
# Copiar a /etc/keepalived/check_nginx.sh en la VM Ubuntu de los 3 PCs:
#   sudo chmod +x /etc/keepalived/check_nginx.sh
# exit 0 = NGINX OK | exit 1 = NGINX caído (Keepalived resta 50 a la prioridad)
curl -fs --max-time 2 http://127.0.0.1:90/health > /dev/null 2>&1
if [ $? -eq 0 ]; then
    exit 0
else
    exit 1
fi
