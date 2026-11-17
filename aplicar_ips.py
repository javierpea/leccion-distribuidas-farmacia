"""
Aplica ips.env a todos los archivos que necesitan IPs o puertos.

    python aplicar_ips.py            (Windows)
    python3 aplicar_ips.py           (VM Ubuntu)

Lee ips.env (el ÚNICO archivo donde se escriben IPs) y regenera, a partir
de la carpeta plantillas/:

    nginx/nginx.conf               upstream con las 2 APIs
    nginx/docker-compose.yml       puerto publicado de NGINX
    keepalived/check_nginx.sh      health check de NGINX
    keepalived/keepalived-server1-master.conf   (y server2 / server3)
    farmacia_app/lib/config_red.dart            IP virtual para la app

La API Flask (backend/config.py) lee ips.env directamente.
Al final imprime los comandos de firewall con las IPs actuales.
Solo usa la librería estándar de Python.
"""
import ipaddress
import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
PLANTILLAS = RAIZ / "plantillas"

OBLIGATORIAS = {
    "IP_SERVER1": "ip", "IP_SERVER2": "ip", "IP_SERVER3": "ip",
    "IP_VIRTUAL": "ip", "MASCARA": "mascara", "INTERFAZ_VM": "interfaz",
    "PUERTO_NGINX": "puerto",
    "IP_API1": "ip", "PUERTO_API1": "puerto",
    "IP_API2": "ip", "PUERTO_API2": "puerto",
    "IP_BD": "ip", "PUERTO_BD": "puerto",
    "RED_PERMITIDA": "red",
}

NODOS = [
    # archivo, nombre, router_id, estado, prioridad, ip, descripción
    ("keepalived-server1-master.conf", "SERVER1 MASTER", "SERVER1_MASTER", "MASTER", 120,
     "IP_SERVER1", "Este es el MASTER: tiene la IP virtual mientras su NGINX esté vivo."),
    ("keepalived-server2-backup1.conf", "SERVER2 ESCLAVO1", "SERVER2_ESCLAVO1", "BACKUP", 110,
     "IP_SERVER2", "ESCLAVO 1: toma la IP virtual si cae el MASTER."),
    ("keepalived-server3-backup2.conf", "SERVER3 ESCLAVO2", "SERVER3_ESCLAVO2", "BACKUP", 100,
     "IP_SERVER3", "ESCLAVO 2: toma la IP virtual si caen el MASTER y el ESCLAVO 1."),
]


def leer_ips(ruta):
    valores = {}
    for n, linea in enumerate(ruta.read_text(encoding="utf-8").splitlines(), 1):
        linea = linea.strip()
        if not linea or linea.startswith("#"):
            continue
        if "=" not in linea:
            sys.exit(f"ips.env línea {n}: falta '=' -> {linea}")
        clave, valor = (p.strip() for p in linea.split("=", 1))
        valores[clave] = valor
    return valores


def validar(v):
    errores = []
    for clave, tipo in OBLIGATORIAS.items():
        valor = v.get(clave)
        if not valor:
            errores.append(f"falta {clave}")
            continue
        try:
            if tipo == "ip":
                ipaddress.IPv4Address(valor)
            elif tipo == "puerto":
                if not (1 <= int(valor) <= 65535):
                    raise ValueError
            elif tipo == "mascara":
                if not (8 <= int(valor) <= 32):
                    raise ValueError
            elif tipo == "red":
                ipaddress.IPv4Network(valor, strict=False)
            elif tipo == "interfaz":
                if not re.fullmatch(r"[A-Za-z0-9._-]{1,15}", valor):
                    raise ValueError
        except ValueError:
            errores.append(f"{clave}={valor} no es válido ({tipo})")
    if errores:
        sys.exit("ips.env tiene errores:\n  - " + "\n  - ".join(errores))

    red = ipaddress.IPv4Network(f"{v['IP_VIRTUAL']}/{v['MASCARA']}", strict=False)
    for clave in ("IP_SERVER1", "IP_SERVER2", "IP_SERVER3"):
        if ipaddress.IPv4Address(v[clave]) not in red:
            print(f"  AVISO: {clave}={v[clave]} no está en la red de la IP virtual ({red}). "
                  "Revise MASCARA.")


def rellenar(texto, valores):
    resultado = re.sub(r"\{\{(\w+)\}\}", lambda m: str(valores[m.group(1)]), texto)
    pendientes = re.findall(r"\{\{\w+\}\}", resultado)
    if pendientes:
        sys.exit(f"Faltan valores para: {pendientes}")
    return resultado


def escribir(relativa, contenido):
    destino = RAIZ / relativa
    destino.parent.mkdir(parents=True, exist_ok=True)
    anterior = destino.read_text(encoding="utf-8") if destino.exists() else None
    # newline="\n": los archivos de Linux (nginx, keepalived, .sh) deben ir con LF
    with open(destino, "w", encoding="utf-8", newline="\n") as f:
        f.write(contenido)
    print(f"  {'(sin cambios)' if anterior == contenido else 'actualizado  '} {relativa}")


def main():
    v = leer_ips(RAIZ / "ips.env")
    validar(v)
    plantilla = lambda nombre: (PLANTILLAS / nombre).read_text(encoding="utf-8")

    print("Aplicando ips.env:")
    escribir("nginx/nginx.conf", rellenar(plantilla("nginx.conf"), v))
    escribir("nginx/docker-compose.yml", rellenar(plantilla("docker-compose.yml"), v))
    escribir("keepalived/check_nginx.sh", rellenar(plantilla("check_nginx.sh"), v))
    for archivo, nombre, rid, estado, prio, ip, desc in NODOS:
        datos = dict(v, NOMBRE_NODO=nombre, ROUTER_ID=rid, ESTADO=estado,
                     PRIORIDAD=prio, IP_NODO=v[ip], DESCRIPCION_NODO=desc)
        escribir(f"keepalived/{archivo}", rellenar(plantilla("keepalived.conf"), datos))
    escribir("farmacia_app/lib/config_red.dart", rellenar(plantilla("config_red.dart"), v))

    print(f"""
Resumen:
  App Flutter  -> http://{v['IP_VIRTUAL']}:{v['PUERTO_NGINX']}   (IP virtual)
  NGINX        -> {v['IP_API1']}:{v['PUERTO_API1']} (entorno 1) y {v['IP_API2']}:{v['PUERTO_API2']} (entorno 2)
  Base de datos-> {v['IP_BD']},{v['PUERTO_BD']}

Firewall (PowerShell como ADMINISTRADOR, una sola vez):
  En {v['IP_API1']} (API {v['PUERTO_API1']}):
    New-NetFirewallRule -DisplayName "API Farmacia {v['PUERTO_API1']}" -Direction Inbound -Protocol TCP -LocalPort {v['PUERTO_API1']} -RemoteAddress {v['RED_PERMITIDA']} -Action Allow
  En {v['IP_API2']} (API {v['PUERTO_API2']}):
    New-NetFirewallRule -DisplayName "API Farmacia {v['PUERTO_API2']}" -Direction Inbound -Protocol TCP -LocalPort {v['PUERTO_API2']} -RemoteAddress {v['RED_PERMITIDA']} -Action Allow
  En {v['IP_BD']} (SQL Server):
    New-NetFirewallRule -DisplayName "SQL Farmacia" -Direction Inbound -Protocol TCP -LocalPort {v['PUERTO_BD']} -RemoteAddress {v['IP_API1']},{v['IP_API2']} -Action Allow

Siguientes pasos:
  1. git add -A ; git commit -m "Cambio de IPs" ; git push
  2. En cada VM:  git pull  y  bash keepalived/instalar_nodo.sh <1|2|3>
  3. Volver a compilar la app Flutter (flutter run) para que tome la IP nueva.
""")


if __name__ == "__main__":
    main()
