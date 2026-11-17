"""Conexión a SQL Server con pyodbc (pooling de ODBC activado)."""
from contextlib import contextmanager

import pyodbc

import config

pyodbc.pooling = True  # ODBC reutiliza las conexiones: barato abrir una por petición


def cadena_conexion():
    cadena = (
        f"DRIVER={{{config.DB_DRIVER}}};"
        f"SERVER={config.DB_SERVER};"
        f"DATABASE={config.DB_DATABASE};"
        "TrustServerCertificate=yes;"
    )
    if config.DB_UID:
        cadena += f"UID={config.DB_UID};PWD={config.DB_PWD or ''};"
    else:
        cadena += "Trusted_Connection=yes;"
    return cadena


def version_a_int(valor):
    """rowversion (8 bytes) -> entero que viaja en el JSON."""
    return int.from_bytes(bytes(valor), "big") if valor is not None else None


def int_a_version(numero):
    """entero del cliente -> 8 bytes para comparar con la columna rowversion."""
    return int(numero).to_bytes(8, "big")


class Cursor:
    """Envuelve el cursor de pyodbc para devolver diccionarios."""

    def __init__(self, cur):
        self._c = cur

    def execute(self, sql, params=None):
        if params:
            self._c.execute(sql, list(params))
        else:
            self._c.execute(sql)
        return self

    @property
    def rowcount(self):
        return self._c.rowcount

    def _a_dict(self, fila):
        columnas = [d[0] for d in self._c.description]
        datos = dict(zip(columnas, fila))
        if "version" in datos:
            datos["version"] = version_a_int(datos["version"])
        return datos

    def fetchone(self):
        fila = self._c.fetchone()
        return None if fila is None else self._a_dict(fila)

    def fetchall(self):
        return [self._a_dict(f) for f in self._c.fetchall()]


@contextmanager
def transaccion():
    """Abre una transacción: COMMIT si todo sale bien, ROLLBACK si hay error.

        with transaccion() as cur:
            cur.execute(...)
    """
    conn = pyodbc.connect(cadena_conexion(), autocommit=False, timeout=5)
    try:
        cur = conn.cursor()
        # Si una fila queda bloqueada más de 10 s se aborta (error 1222)
        cur.execute("SET LOCK_TIMEOUT 10000")
        yield Cursor(cur)
        conn.commit()
    except Exception:
        try:
            conn.rollback()
        except pyodbc.Error:
            pass
        raise
    finally:
        conn.close()
