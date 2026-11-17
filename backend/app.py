"""
API REST - FARMACIA - Grupo 3 - Tabla: dbo.medicamentos (SQL Server)
=====================================================================
Se ejecuta DOS veces (una por integrante / servidor):

    python app.py --port 5000          (server1 - 10.79.5.86)
    python app.py --port 5001          (server2 - 10.79.4.177)

Nginx reparte las peticiones entre ambas y Keepalived da la IP virtual.

CONCURRENCIA (igual que en facturación):
  1. SELECT ... WITH (UPDLOCK, ROWLOCK) bloquea la fila: si dos peticiones
     llegan al mismo tiempo (una por el 5000 y otra por el 5001), la
     segunda ESPERA a que la primera termine y ve los datos ya cambiados.
  2. La columna `version` (ROWVERSION): el cliente envía la versión que
     leyó; si alguien cambió el registro antes -> 409.
  3. El UPDATE repite la condición en el WHERE (version / stock) como
     guardia final, y la BD tiene CHECK (stock >= 0).
"""
import argparse
import os
import re
import time
from datetime import date, datetime
from decimal import Decimal

import pyodbc
from flask import Flask, jsonify, request

import config
import validators as v
from db import int_a_version, transaccion

app = Flask(__name__)
app.json.ensure_ascii = False
app.json.sort_keys = False
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024  # 16 KB por petición

SERVIDOR = os.getenv("SERVIDOR", "flask-5000")
TABLA = "dbo.medicamentos"

# Mensajes amigables para cada control de la base de datos
MENSAJES_BD = {
    "uq_medicamentos_nombre": ("nombre_comercial", "Ya existe un medicamento con ese nombre"),
    "uq_medicamentos_codigo": ("codigo", "Ya existe un medicamento con ese código"),
    "uq_medicamentos_registro": ("registro_sanitario", "Ese registro sanitario ya está registrado"),
    "chk_codigo_formato": ("codigo", "Formato de código inválido (MED-0001)"),
    "chk_nombre_solo_letras": ("nombre_comercial", "El nombre solo admite letras (3 a 100)"),
    "chk_principio_solo_letras": ("principio_activo", "El principio activo solo admite letras"),
    "chk_laboratorio_solo_letras": ("laboratorio", "El laboratorio solo admite letras"),
    "chk_concentracion_formato": ("concentracion", "Concentración inválida (500 mg, 250 mg/5 ml)"),
    "chk_forma_valida": ("forma_farmaceutica", "Forma farmacéutica no válida"),
    "chk_registro_formato": ("registro_sanitario", "Registro sanitario inválido"),
    "chk_lote_formato": ("lote", "Lote inválido (letras mayúsculas y números)"),
    "chk_fechas_orden": ("fecha_vencimiento", "El vencimiento debe ser posterior a la fabricación"),
    "chk_stock_no_negativo": ("stock", "El stock no puede ser negativo (máx. 100000)"),
    "chk_stock_minimo": ("stock_minimo", "Stock mínimo fuera de rango"),
    "chk_precio_compra": ("precio_compra", "El precio de compra debe ser mayor a 0"),
    "chk_precio_venta_mayor": ("precio_venta", "El precio de venta no puede ser menor al de compra"),
    "chk_precio_venta": ("precio_venta", "El precio de venta debe ser mayor a 0"),
    "chk_estado_valido": ("estado", "Estado no válido"),
}
ERRORES_TIPO_DATO = {241, 242, 245, 8114, 8115, 8152, 2628, 220, 248, 295}


# =====================================================================
# Utilidades de respuesta
# =====================================================================
def serializar(fila):
    if fila is None:
        return None
    out = {}
    for k, valor in fila.items():
        if isinstance(valor, Decimal):
            valor = float(valor)
        elif isinstance(valor, (date, datetime)):
            valor = valor.isoformat()
        out[k] = valor
    return out


def ok(cuerpo, status=200):
    cuerpo["servidor"] = SERVIDOR
    return jsonify(cuerpo), status


def error(status, motivo, mensaje, errores=None, medicamento=None):
    cuerpo = {"error": mensaje, "motivo": motivo, "servidor": SERVIDOR}
    if errores:
        cuerpo["errores"] = errores
    if medicamento is not None:
        cuerpo["medicamento"] = serializar(medicamento)
    return jsonify(cuerpo), status


def conflicto(motivo, mensaje, medicamento=None):
    return error(409, motivo, mensaje, medicamento=medicamento)


def leer_json():
    datos = request.get_json(silent=True)
    if datos is None:
        return None, error(400, "validacion", "El cuerpo debe ser JSON válido "
                                              "(Content-Type: application/json)")
    return datos, None


def version_bytes(valor):
    """Convierte la versión que envía el cliente a los 8 bytes del ROWVERSION."""
    try:
        return int_a_version(valor)
    except (TypeError, ValueError, OverflowError):
        return None


def preparar_medicamento(datos, es_actualizacion):
    """Aplica los controles del backend (o los salta en modo demo)."""
    if not config.DESACTIVAR_VALIDACION_BACKEND:
        return v.validar_medicamento(datos, es_actualizacion)
    if not isinstance(datos, dict):
        return {}, {"_general": "El cuerpo debe ser un objeto JSON"}
    permitidos = v.CAMPOS_ACTUALIZAR if es_actualizacion else v.CAMPOS_CREAR
    crudo = {k: datos[k] for k in permitidos if k in datos}
    if not es_actualizacion:
        for k, por_defecto in v.OPCIONALES.items():
            crudo.setdefault(k, por_defecto)
    return crudo, {}


def leer_fila(cur, mid, bloquear=False):
    pista = " WITH (UPDLOCK, ROWLOCK)" if bloquear else ""
    return cur.execute(f"SELECT * FROM {TABLA}{pista} WHERE id = ?", [mid]).fetchone()


def buscar_duplicados(cur, datos, excluir_id=None):
    """Control del backend ANTES de tocar la BD. Si dos peticiones pasan
    este control a la vez, el UNIQUE de la BD detiene a la segunda.
    (La columna usa collation CI_AI: ignora mayúsculas y tildes.)"""
    errores = {}
    excluir = excluir_id or 0
    if "nombre_comercial" in datos:
        fila = cur.execute(f"SELECT codigo FROM {TABLA} WHERE nombre_comercial = ? AND id <> ?",
                           [datos["nombre_comercial"], excluir]).fetchone()
        if fila:
            errores["nombre_comercial"] = f"Ya existe un medicamento con ese nombre ({fila['codigo']})"
    if "codigo" in datos and not excluir_id:
        if cur.execute(f"SELECT 1 AS x FROM {TABLA} WHERE codigo = ?", [datos["codigo"]]).fetchone():
            errores["codigo"] = "Ya existe un medicamento con ese código"
    if "registro_sanitario" in datos:
        fila = cur.execute(f"SELECT codigo FROM {TABLA} WHERE registro_sanitario = ? AND id <> ?",
                           [datos["registro_sanitario"], excluir]).fetchone()
        if fila:
            errores["registro_sanitario"] = f"Registro sanitario ya usado por {fila['codigo']}"
    return errores


# =====================================================================
# Middleware: cabecera X-Server (para ver el balanceo) y CORS
# =====================================================================
@app.after_request
def cabeceras(resp):
    resp.headers["X-Server"] = SERVIDOR
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    resp.headers["Access-Control-Expose-Headers"] = "X-Server"
    return resp


# =====================================================================
# Errores de SQL Server -> respuestas JSON (segunda línea de defensa)
# =====================================================================
@app.errorhandler(pyodbc.Error)
def error_bd(e):
    sqlstate = str(e.args[0]) if e.args else ""
    texto = " ".join(str(a) for a in e.args)
    numeros = [int(n) for n in re.findall(r"\((\d+)\)", texto)]
    numero = numeros[0] if numeros else None

    if sqlstate.startswith("08") or sqlstate in ("HYT00", "HYT01") or numero in (4060, 18456):
        return error(503, "bd_no_disponible", "No se pudo conectar con la base de datos")

    if numero == 1222:
        return conflicto("bloqueo", "El registro está siendo modificado por otro usuario. Intente de nuevo.")

    restriccion = next((n for n in MENSAJES_BD if n in texto), None)
    if numero in (2627, 2601):
        campo, msg = MENSAJES_BD.get(restriccion, (None, "Registro duplicado"))
        return error(409, "duplicado", f"[BD] {msg}", {campo: msg} if campo else None)

    if numero == 547:
        campo, msg = MENSAJES_BD.get(restriccion, (None, "Control de la base de datos violado"))
        return error(400, "control_bd", f"[BD] {msg}", {campo: msg} if campo else None)

    if numero and 50000 < numero < 50100:  # THROW de los triggers
        m = re.search(r"\[SQL Server\](.+?)\s*\(\d+\)", texto)
        return error(400, "control_bd", f"[BD] {m.group(1) if m else 'Regla de negocio violada'}")

    if numero == 515:
        return error(400, "control_bd", "[BD] Falta un campo obligatorio")

    if numero in ERRORES_TIPO_DATO or sqlstate.startswith("22"):
        return error(400, "control_bd", "[BD] Tipo de dato inválido (revise números, textos y fechas)")

    app.logger.exception("Error de BD no controlado")
    return error(500, "interno", "Error de base de datos")


@app.errorhandler(404)
def _404(e):
    return error(404, "no_encontrado", "Ruta no encontrada")


@app.errorhandler(405)
def _405(e):
    return error(405, "metodo", "Método no permitido")


@app.errorhandler(413)
def _413(e):
    return error(413, "validacion", "Petición demasiado grande")


@app.errorhandler(500)
def _500(e):
    return error(500, "interno", "Error interno del servidor")


# =====================================================================
# ENDPOINTS
# =====================================================================
@app.get("/api/health")
def health():
    """Lo usan Nginx y la app (pantalla de mantenimiento)."""
    try:
        with transaccion() as cur:
            cur.execute("SELECT 1 AS ok").fetchone()
        return ok({"status": "ok"})
    except pyodbc.Error:
        return error(503, "bd_no_disponible", "Base de datos no disponible")


@app.get("/api/medicamentos")
def listar():
    q, err = v.validar_busqueda(request.args.get("q"))
    if err:
        return error(400, "validacion", err, {"q": err})

    filtros, params = [], []
    if q:  # collation CI_AI: no distingue mayúsculas ni tildes
        filtros.append("(nombre_comercial LIKE ? OR principio_activo LIKE ? OR codigo LIKE ?)")
        params += [f"%{q}%"] * 3

    estado = request.args.get("estado")
    if estado:
        estado = estado.strip().upper()
        if estado not in v.ESTADOS:
            return error(400, "validacion", "Estado no válido")
        filtros.append("estado = ?")
        params.append(estado)

    receta = request.args.get("requiere_receta")
    if receta is not None:
        if receta not in ("true", "false"):
            return error(400, "validacion", "requiere_receta debe ser true o false")
        filtros.append("requiere_receta = ?")
        params.append(1 if receta == "true" else 0)

    pagina, e1 = v.entero(request.args.get("pagina", "1"), "pagina", 1, 100000)
    tam, e2 = v.entero(request.args.get("tam", "50"), "tam", 1, 100)
    if e1 or e2:
        return error(400, "validacion", e1 or e2)

    where = ("WHERE " + " AND ".join(filtros)) if filtros else ""
    with transaccion() as cur:
        total = cur.execute(f"SELECT COUNT(*) AS total FROM {TABLA} {where}", params).fetchone()["total"]
        filas = cur.execute(
            f"SELECT * FROM {TABLA} {where} ORDER BY id OFFSET ? ROWS FETCH NEXT ? ROWS ONLY",
            params + [(pagina - 1) * tam, tam]).fetchall()
    return ok({"datos": [serializar(f) for f in filas], "total": total,
               "pagina": pagina, "tam": tam})


@app.get("/api/medicamentos/alertas")
def alertas():
    with transaccion() as cur:
        filas = cur.execute(f"""
            SELECT *,
                   CAST(CASE WHEN stock <= stock_minimo THEN 1 ELSE 0 END AS BIT) AS stock_bajo,
                   CAST(CASE WHEN fecha_vencimiento <= DATEADD(DAY, 60, CAST(GETDATE() AS DATE))
                             THEN 1 ELSE 0 END AS BIT) AS por_vencer
              FROM {TABLA}
             WHERE estado = 'ACTIVO'
               AND (stock <= stock_minimo
                    OR fecha_vencimiento <= DATEADD(DAY, 60, CAST(GETDATE() AS DATE)))
             ORDER BY fecha_vencimiento""").fetchall()
    return ok({"datos": [serializar(f) for f in filas], "total": len(filas)})


@app.get("/api/medicamentos/<int:mid>")
def obtener(mid):
    with transaccion() as cur:
        fila = leer_fila(cur, mid)
    if not fila:
        return error(404, "no_encontrado", f"No existe el medicamento {mid}")
    return ok({"medicamento": serializar(fila)})


@app.post("/api/medicamentos")
def crear():
    datos, err = leer_json()
    if err:
        return err
    limpio, errores = preparar_medicamento(datos, es_actualizacion=False)
    if errores:
        return error(400, "validacion", "Datos inválidos", errores)

    with transaccion() as cur:
        if not config.DESACTIVAR_VALIDACION_BACKEND:
            dup = buscar_duplicados(cur, limpio)
            if dup:
                return error(409, "duplicado", "Registro duplicado", dup)
        columnas = list(limpio.keys())  # siempre de la lista blanca de validators
        nuevo_id = cur.execute(
            f"SET NOCOUNT ON; INSERT INTO {TABLA} ({', '.join(columnas)}) "
            f"VALUES ({', '.join(['?'] * len(columnas))}); "
            "SELECT CAST(SCOPE_IDENTITY() AS INT) AS id;",
            [limpio[c] for c in columnas]).fetchone()["id"]
        nuevo = leer_fila(cur, nuevo_id)
    return ok({"mensaje": "Medicamento creado", "medicamento": serializar(nuevo)}, 201)


@app.put("/api/medicamentos/<int:mid>")
def actualizar(mid):
    datos, err = leer_json()
    if err:
        return err
    limpio, errores = preparar_medicamento(datos, es_actualizacion=True)
    if errores:
        return error(400, "validacion", "Datos inválidos", errores)

    version = limpio.pop("version", None)
    codigo = limpio.pop("codigo", None)
    vbytes = version_bytes(version) if version is not None else None
    if vbytes is None:
        return error(400, "validacion", "version es obligatoria",
                     {"version": "Envíe la versión que leyó"})
    if not limpio:
        return error(400, "validacion", "No hay campos para actualizar")

    with transaccion() as cur:
        # 1) Bloqueo pesimista de la fila (UPDLOCK, como en facturación)
        actual = leer_fila(cur, mid, bloquear=True)
        if not actual:
            return error(404, "no_encontrado", f"No existe el medicamento {mid}")

        # 2) Concurrencia optimista: ¿alguien lo modificó desde que lo leí?
        if actual["version"] != int(version):
            return conflicto(
                "concurrencia",
                f"'{actual['nombre_comercial']}' fue modificado por otro usuario. "
                "Recargue e intente de nuevo.",
                actual)

        if not config.DESACTIVAR_VALIDACION_BACKEND:
            if codigo is not None and codigo != actual["codigo"]:
                return error(400, "validacion", "El código no se puede modificar",
                             {"codigo": "No se puede modificar"})
            if actual["estado"] == "RETIRADO":
                return conflicto("estado", "Un medicamento RETIRADO no se puede modificar", actual)
            if limpio.get("stock", actual["stock"]) < actual["stock"] \
                    and limpio.get("estado", actual["estado"]) != "ACTIVO":
                return error(400, "validacion", "Solo se puede despachar stock de medicamentos ACTIVOS")
            dup = buscar_duplicados(cur, limpio, excluir_id=mid)
            if dup:
                return error(409, "duplicado", "Registro duplicado", dup)
            fab = limpio.get("fecha_fabricacion", actual["fecha_fabricacion"])
            ven = limpio.get("fecha_vencimiento", actual["fecha_vencimiento"])
            if ven <= fab:
                return error(400, "validacion", "Datos inválidos",
                             {"fecha_vencimiento": "Debe ser posterior a la fabricación"})
            pc = limpio.get("precio_compra", actual["precio_compra"])
            pv = limpio.get("precio_venta", actual["precio_venta"])
            if pv < pc:
                return error(400, "validacion", "Datos inválidos",
                             {"precio_venta": "No puede ser menor al precio de compra"})

        # 3) Guardia final en el WHERE (SQL Server cambia el ROWVERSION solo)
        columnas = list(limpio.keys())
        cur.execute(
            f"UPDATE {TABLA} SET {', '.join(c + ' = ?' for c in columnas)}, "
            "actualizado_en = SYSDATETIME() WHERE id = ? AND version = ?",
            [limpio[c] for c in columnas] + [mid, vbytes])
        if cur.rowcount == 0:
            return conflicto("concurrencia", "El registro cambió mientras se guardaba. Recargue.")
        nuevo = leer_fila(cur, mid)
    return ok({"mensaje": "Medicamento actualizado", "medicamento": serializar(nuevo)})


@app.patch("/api/medicamentos/<int:mid>/stock")
def mover_stock(mid):
    """ENTRADA suma, SALIDA (despacho) resta. Es el endpoint para la
    prueba de concurrencia: N clientes despachan el mismo medicamento
    a la vez y el stock NUNCA queda negativo."""
    datos, err = leer_json()
    if err:
        return err
    mov, errores = v.validar_movimiento_stock(datos)
    if errores:
        return error(400, "validacion", "Datos inválidos", errores)

    # ?demora=ms  -> retiene el bloqueo para que la espera se vea en la demo
    demora, e = v.entero(request.args.get("demora", "0"), "demora", 0, 3000)
    if e:
        return error(400, "validacion", e)

    cantidad = mov["cantidad"]
    delta = cantidad if mov["operacion"] == "ENTRADA" else -cantidad

    with transaccion() as cur:
        actual = leer_fila(cur, mid, bloquear=True)
        if not actual:
            return error(404, "no_encontrado", f"No existe el medicamento {mid}")
        if demora:
            time.sleep(demora / 1000)

        nombre = actual["nombre_comercial"]
        if not config.DESACTIVAR_VALIDACION_BACKEND:
            if mov["operacion"] == "SALIDA":
                if actual["estado"] != "ACTIVO":
                    return conflicto("estado", f"'{nombre}' está {actual['estado']}, no se puede despachar", actual)
                if actual["fecha_vencimiento"] <= date.today():
                    return conflicto("vencido", f"'{nombre}' está vencido, no se puede despachar", actual)
                if actual["stock"] < cantidad:
                    msg = (f"Ya no hay stock de '{nombre}'. Otro usuario lo despachó."
                           if actual["stock"] == 0 else
                           f"Stock insuficiente de '{nombre}': pidió {cantidad}, quedan {actual['stock']}.")
                    return conflicto("stock", msg, actual)
            else:
                if actual["estado"] == "RETIRADO":
                    return conflicto("estado", f"'{nombre}' está RETIRADO", actual)
                if actual["stock"] + cantidad > v.STOCK_MAX:
                    return error(400, "validacion", f"El stock no puede superar {v.STOCK_MAX}")

        # Guardia final: la condición vuelve a estar en el WHERE
        cur.execute(
            f"UPDATE {TABLA} SET stock = stock + ?, actualizado_en = SYSDATETIME() "
            "WHERE id = ? AND stock + ? >= 0",
            [delta, mid, delta])
        if cur.rowcount == 0:
            return conflicto("stock", f"Stock insuficiente de '{nombre}' (quedan {actual['stock']})", actual)
        nuevo = leer_fila(cur, mid)

    return ok({"mensaje": f"{mov['operacion']} de {cantidad} unidad(es) registrada",
               "stock_anterior": actual["stock"], "medicamento": serializar(nuevo)})


@app.delete("/api/medicamentos/<int:mid>")
def eliminar(mid):
    """Borrado LÓGICO (estado = INACTIVO). Exige ?version=N."""
    version, e = v.entero(request.args.get("version", ""), "version", 1, 2**63 - 1)
    if e:
        return error(400, "validacion", "Envíe ?version= con la versión que leyó")

    with transaccion() as cur:
        actual = leer_fila(cur, mid, bloquear=True)
        if not actual:
            return error(404, "no_encontrado", f"No existe el medicamento {mid}")
        if actual["version"] != version:
            return conflicto("concurrencia",
                             f"'{actual['nombre_comercial']}' fue modificado por otro usuario. Recargue.",
                             actual)
        if actual["stock"] > 0:
            return conflicto("stock",
                             f"No se puede eliminar: aún tiene {actual['stock']} unidades en stock", actual)
        if actual["estado"] == "INACTIVO":
            return conflicto("estado", "El medicamento ya está inactivo", actual)
        cur.execute(f"UPDATE {TABLA} SET estado = 'INACTIVO', actualizado_en = SYSDATETIME() "
                    "WHERE id = ? AND version = ?", [mid, int_a_version(version)])
        if cur.rowcount == 0:
            return conflicto("concurrencia", "El registro cambió mientras se eliminaba. Recargue.")
        nuevo = leer_fila(cur, mid)
    return ok({"mensaje": "Medicamento dado de baja (INACTIVO)", "medicamento": serializar(nuevo)})


# =====================================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="API Farmacia - medicamentos")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--nombre", help="Nombre del servidor (cabecera X-Server)")
    args = parser.parse_args()

    SERVIDOR = args.nombre or f"flask-{args.port}"
    print(f" * {SERVIDOR} -> SQL Server {config.DB_SERVER} / {config.DB_DATABASE}")
    if config.DESACTIVAR_VALIDACION_BACKEND:
        print(" * ATENCIÓN: validación del backend DESACTIVADA (solo controla la BD)")
    # threaded=True: atiende varias peticiones a la vez (necesario para concurrencia)
    app.run(host=args.host, port=args.port, threaded=True, debug=False)
