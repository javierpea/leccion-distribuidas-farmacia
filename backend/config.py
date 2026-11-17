"""Configuración leída de variables de entorno (o del archivo .env).

Mismos nombres que en facturación:  DB_SERVER, DB_DATABASE, DB_UID, DB_PWD, DB_DRIVER
Si no hay DB_UID se usa autenticación de Windows.
"""
import os

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:  # python-dotenv es opcional
    pass

DB_DRIVER = os.getenv("DB_DRIVER", "ODBC Driver 17 for SQL Server")
DB_SERVER = os.getenv("DB_SERVER", r"(localdb)\MSSQLLocalDB")
DB_DATABASE = os.getenv("DB_DATABASE", "AppDistribuidas_2026_DB")
DB_UID = os.getenv("DB_UID")
DB_PWD = os.getenv("DB_PWD")

# Solo para la DEMO de "defensa en profundidad": con 1 se apagan los
# controles del backend y se ve que la BD igual rechaza los datos malos.
DESACTIVAR_VALIDACION_BACKEND = os.getenv("DESACTIVAR_VALIDACION_BACKEND", "0") == "1"
