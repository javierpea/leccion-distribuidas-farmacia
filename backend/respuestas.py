"""Respuestas JSON comunes de la API (las usan app.py y auth.py)."""
from datetime import date, datetime
from decimal import Decimal

from flask import jsonify

# Nombre del servidor que atendió (cabecera X-Server). Lo fija app.py al
# arrancar:  python app.py --port 5000 --nombre cliente-5000
SERVIDOR = "flask-5000"


def serializar(fila):
    if fila is None:
        return None
    out = {}
    for k, valor in fila.items():
        if isinstance(valor, Decimal):
            valor = float(valor)
        elif isinstance(valor, (date, datetime)):
            valor = valor.isoformat()
        elif isinstance(valor, (bytes, bytearray)):
            continue  # nunca se envían binarios (hash, etc.)
        out[k] = valor
    return out


def ok(cuerpo, status=200):
    cuerpo["servidor"] = SERVIDOR
    return jsonify(cuerpo), status


def error(status, motivo, mensaje, errores=None, medicamento=None, usuario=None):
    cuerpo = {"error": mensaje, "motivo": motivo, "servidor": SERVIDOR}
    if errores:
        cuerpo["errores"] = errores
    if medicamento is not None:
        cuerpo["medicamento"] = serializar(medicamento)
    if usuario is not None:
        cuerpo["usuario"] = serializar(usuario)
    return jsonify(cuerpo), status
