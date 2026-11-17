"""Configuración de la API.

1. ../ips.env  -> IPs y puertos (el ÚNICO archivo de IPs del proyecto)
2. .env        -> datos propios de cada entorno (credenciales de la BD,
                  claves de Google/Facebook). Puede usar ${IP_BD} y
                  ${PUERTO_BD} de ips.env, por ejemplo:
                      DB_SERVER=${IP_BD},${PUERTO_BD}

Si no hay DB_UID se usa autenticación de Windows.
"""
import os
from pathlib import Path

CARPETA = Path(__file__).resolve().parent
ARCHIVO_IPS = CARPETA.parent / "ips.env"


def _cargar_ips(ruta):
    """Lee ips.env sin depender de librerías (KEY=valor, # comentarios)."""
    if not ruta.exists():
        return
    for linea in ruta.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if linea and not linea.startswith("#") and "=" in linea:
            clave, valor = (p.strip() for p in linea.split("=", 1))
            os.environ.setdefault(clave, valor)


_cargar_ips(ARCHIVO_IPS)
try:
    from dotenv import load_dotenv
    load_dotenv(CARPETA / ".env")      # ${IP_BD} se reemplaza con el valor de ips.env
except ImportError:  # python-dotenv es opcional
    pass

# ---------------- Base de datos ----------------
DB_DRIVER = os.getenv("DB_DRIVER", "ODBC Driver 17 for SQL Server")
DB_SERVER = os.getenv("DB_SERVER", r"localhost\SQLEXPRESS")
DB_DATABASE = os.getenv("DB_DATABASE", "AppDistribuidas_2026_DB")
DB_UID = os.getenv("DB_UID")
DB_PWD = os.getenv("DB_PWD")

# ---------------- Sesión (Unidad 3) ----------------
# Duración del token en minutos (el PDF usa 5). Al expirar -> 401 y la
# app vuelve al login con "Sesión expirada".
TOKEN_MINUTOS = int(os.getenv("TOKEN_MINUTOS", "5"))

# ---------------- Login con Google / Facebook ----------------
# Si están vacíos, la app oculta esos botones.
GOOGLE_CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID", "")
GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET", "")
FACEBOOK_APP_ID = os.getenv("FACEBOOK_APP_ID", "")
FACEBOOK_APP_SECRET = os.getenv("FACEBOOK_APP_SECRET", "")
# La app abre el navegador y recibe la respuesta en esta dirección local
OAUTH_REDIRECT_URI = os.getenv("OAUTH_REDIRECT_URI", "http://localhost:8765/callback")

# Solo para la DEMO de "defensa en profundidad": con 1 se apagan los
# controles del backend y se ve que la BD igual rechaza los datos malos.
DESACTIVAR_VALIDACION_BACKEND = os.getenv("DESACTIVAR_VALIDACION_BACKEND", "0") == "1"
