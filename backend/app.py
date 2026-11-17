"""
API REST - FARMACIA - Grupo 3 (SQL Server + login con roles)
=====================================================================
Se ejecuta en DOS entornos independientes (IPs y puertos en ../ips.env):

    python app.py --port 5000 --nombre cliente-5000      (entorno 1)
    python app.py --port 5001 --nombre server1-5001      (entorno 2)

NGINX reparte las peticiones entre ambas y Keepalived da la IP virtual.

La API SOLO usa las vistas y procedimientos de 02_vistas_procedimientos.sql:
    vw_catalogo, vw_medicamentos, vw_medicamentos_alertas, vw_usuarios,
    vw_movimientos_stock, sp_auth_*, sp_usuario_*, sp_medicamento_*

Tres capas de control (defensa en profundidad):
    1. Flutter: el teclado solo deja escribir lo permitido.
    2. Esta API: validators.py revisa cada campo + permisos por rol.
    3. SQL Server: CHECK, UNIQUE, triggers y la lógica de los SP.

CONCURRENCIA (dentro de los procedimientos):
    UPDLOCK (bloqueo de fila) + ROWVERSION (versión) + guardia en el WHERE.
"""
import argparse
import re

import pyodbc
from flask import Flask, g, request

import auth
import config
import respuestas
import validators as v
from auth import ROLES_PERSONAL, requiere_rol
from db import int_a_version, transaccion
from respuestas import error, ok, serializar

app = Flask(__name__)
app.json.ensure_ascii = False
app.json.sort_keys = False
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024  # 16 KB por petición

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
    "uq_usuarios_usuario": ("usuario", "Ese nombre de usuario ya está registrado"),
    "uq_usuarios_email": ("email", "Ese correo ya está registrado"),
    "chk_usuario_formato": ("usuario", "Usuario: minúsculas, números, punto o guion bajo (4 a 30)"),
    "chk_usuario_nombre": ("nombre_completo", "El nombre solo admite letras (3 a 100)"),
    "chk_usuario_email": ("email", "Correo inválido"),
    "chk_usuario_rol": ("rol", "Rol no válido"),
    "chk_mov_cuadre": ("cantidad", "El movimiento de stock no cuadra"),
}
ERRORES_TIPO_DATO = {241, 242, 245, 8114, 8115, 8152, 2628, 220, 248, 295}

# THROW de los procedimientos -> (status HTTP, motivo)
ERRORES_SP = {
    52001: (409, "concurrencia"), 52002: (409, "stock"), 52003: (409, "estado"),
    52004: (404, "no_encontrado"), 52005: (409, "vencido"), 52006: (400, "validacion"),
    52007: (400, "validacion"),
    53001: (409, "duplicado"), 53002: (409, "duplicado"), 53003: (400, "validacion"),
    53004: (404, "no_encontrado"), 53005: (409, "permiso"), 53006: (400, "validacion"),
    53007: (409, "permiso"),
    50011: (409, "permiso"),
}
CAMPO_ERROR_SP = {53001: "usuario", 53002: "email", 53003: "password"}

# Resultado de sp_auth_login / sp_auth_login_social -> status HTTP
RESULTADOS_LOGIN = {"CREDENCIALES": 401, "BLOQUEADO": 423, "INACTIVO": 403,
                    "SOCIAL": 409, "EMAIL_EXISTE": 409}


# =====================================================================
# Utilidades
# =====================================================================
def leer_json():
    datos = request.get_json(silent=True)
    if datos is None:
        return None, error(400, "validacion", "El cuerpo debe ser JSON válido "
                                              "(Content-Type: application/json)")
    return datos, None


def numero_error(e):
    texto = " ".join(str(a) for a in e.args)
    m = re.search(r"\((\d+)\)\s*\(SQL", texto) or re.search(r"\((\d+)\)", texto)
    return (int(m.group(1)) if m else None), texto


def mensaje_sql(texto, por_defecto="Regla de negocio violada"):
    m = re.search(r"\[SQL Server\](.+?)\s*\(\d+\)\s*(\(SQL|$)", texto)
    return m.group(1).strip() if m else por_defecto


def leer_medicamento(mid):
    with transaccion() as cur:
        return cur.execute("SELECT * FROM dbo.vw_medicamentos WHERE id = ?", [mid]).fetchone()


def leer_usuario(uid):
    with transaccion() as cur:
        return cur.execute("SELECT * FROM dbo.vw_usuarios WHERE id = ?", [uid]).fetchone()


def ejecutar_con_conflicto(funcion, leer_actual=None, clave="medicamento"):
    """Ejecuta un SP. Si devuelve un conflicto (409), adjunta los datos
    ACTUALES de la BD para que la app los muestre ("otro usuario lo cambió")."""
    try:
        return funcion()
    except pyodbc.Error as e:
        numero, texto = numero_error(e)
        if numero in ERRORES_SP:
            status, motivo = ERRORES_SP[numero]
            actual = leer_actual() if (leer_actual and status == 409) else None
            campo = CAMPO_ERROR_SP.get(numero)
            msg = mensaje_sql(texto)
            return error(status, motivo, msg, {campo: msg} if campo else None,
                         **({clave: actual} if actual else {}))
        raise


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


def buscar_duplicados(cur, datos, excluir_id=None):
    """Control del backend ANTES de llamar al SP. Si dos peticiones pasan
    este control a la vez, el UNIQUE de la BD detiene a la segunda."""
    errores = {}
    excluir = excluir_id or 0
    if "nombre_comercial" in datos:
        fila = cur.execute("SELECT codigo FROM dbo.vw_medicamentos WHERE nombre_comercial = ? AND id <> ?",
                           [datos["nombre_comercial"], excluir]).fetchone()
        if fila:
            errores["nombre_comercial"] = f"Ya existe un medicamento con ese nombre ({fila['codigo']})"
    if "codigo" in datos and not excluir_id:
        if cur.execute("SELECT 1 AS x FROM dbo.vw_medicamentos WHERE codigo = ?",
                       [datos["codigo"]]).fetchone():
            errores["codigo"] = "Ya existe un medicamento con ese código"
    if "registro_sanitario" in datos:
        fila = cur.execute("SELECT codigo FROM dbo.vw_medicamentos WHERE registro_sanitario = ? AND id <> ?",
                           [datos["registro_sanitario"], excluir]).fetchone()
        if fila:
            errores["registro_sanitario"] = f"Registro sanitario ya usado por {fila['codigo']}"
    return errores


def paginacion():
    pagina, e1 = v.entero(request.args.get("pagina", "1"), "pagina", 1, 100000)
    tam, e2 = v.entero(request.args.get("tam", "50"), "tam", 1, 100)
    return pagina, tam, (e1 or e2)


def respuesta_login(fila):
    """Convierte la fila de sp_auth_login(_social) en la respuesta HTTP."""
    if fila["resultado"] != "OK":
        status = RESULTADOS_LOGIN.get(fila["resultado"], 401)
        return error(status, fila["resultado"].lower(), fila["mensaje"])
    usuario = {k: fila[k] for k in ("id", "usuario", "nombre_completo", "email", "rol", "proveedor")}
    return ok({"mensaje": fila["mensaje"], "usuario": usuario, "token": fila["token"],
               "expiracion": fila["expiracion"].isoformat(),
               "minutos": config.TOKEN_MINUTOS})


# =====================================================================
# Middleware: cabecera X-Server (para ver el balanceo) y CORS
# =====================================================================
@app.after_request
def cabeceras(resp):
    resp.headers["X-Server"] = respuestas.SERVIDOR
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    resp.headers["Access-Control-Expose-Headers"] = "X-Server"
    return resp


# =====================================================================
# Errores de SQL Server -> respuestas JSON (segunda línea de defensa)
# =====================================================================
@app.errorhandler(pyodbc.Error)
def error_bd(e):
    sqlstate = str(e.args[0]) if e.args else ""
    numero, texto = numero_error(e)

    if sqlstate.startswith("08") or sqlstate in ("HYT00", "HYT01") or numero in (4060, 18456):
        return error(503, "bd_no_disponible", "No se pudo conectar con la base de datos")

    if numero == 1222:
        return error(409, "bloqueo", "El registro está siendo modificado por otro usuario. Intente de nuevo.")

    if numero in ERRORES_SP:
        status, motivo = ERRORES_SP[numero]
        campo = CAMPO_ERROR_SP.get(numero)
        msg = mensaje_sql(texto)
        return error(status, motivo, msg, {campo: msg} if campo else None)

    restriccion = next((n for n in MENSAJES_BD if n in texto), None)
    if numero in (2627, 2601):
        campo, msg = MENSAJES_BD.get(restriccion, (None, "Registro duplicado"))
        return error(409, "duplicado", f"[BD] {msg}", {campo: msg} if campo else None)

    if numero == 547:
        campo, msg = MENSAJES_BD.get(restriccion, (None, "Control de la base de datos violado"))
        return error(400, "control_bd", f"[BD] {msg}", {campo: msg} if campo else None)

    if numero and 50000 < numero < 50100:  # THROW de los triggers
        return error(400, "control_bd", f"[BD] {mensaje_sql(texto)}")

    if numero in (515, 201):  # columna NOT NULL / parámetro del SP sin enviar
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
# SALUD (sin token: la usan NGINX y la pantalla de mantenimiento)
# =====================================================================
@app.get("/api/health")
def health():
    try:
        with transaccion() as cur:
            cur.execute("SELECT 1 AS ok").fetchone()
        return ok({"status": "ok"})
    except pyodbc.Error:
        return error(503, "bd_no_disponible", "Base de datos no disponible")


# =====================================================================
# AUTENTICACIÓN (Unidad 3)
# =====================================================================
@app.get("/api/auth/config")
def auth_config():
    """La app pregunta qué botones de login mostrar (Google / Facebook)."""
    activos = auth.social_habilitado()
    return ok({
        "google": activos["GOOGLE"],
        "facebook": activos["FACEBOOK"],
        "google_client_id": config.GOOGLE_CLIENT_ID if activos["GOOGLE"] else "",
        "facebook_app_id": config.FACEBOOK_APP_ID if activos["FACEBOOK"] else "",
        "redirect_uri": config.OAUTH_REDIRECT_URI,
        "token_minutos": config.TOKEN_MINUTOS,
    })


@app.post("/api/auth/login")
def login():
    datos, err = leer_json()
    if err:
        return err
    cred, errores = v.validar_login(datos)
    if errores:
        return error(400, "validacion", "Ingrese usuario y contraseña", errores)
    with transaccion() as cur:
        fila = cur.sp("sp_auth_login", usuario=cred["usuario"], password=cred["password"],
                      minutos=config.TOKEN_MINUTOS, ip=request.remote_addr).fetchone()
    return respuesta_login(fila)


@app.post("/api/auth/registro")
def registro():
    """Registro público: SIEMPRE crea un CLIENTE y deja la sesión iniciada."""
    datos, err = leer_json()
    if err:
        return err
    limpio, errores = v.validar_registro(datos)
    if errores:
        return error(400, "validacion", "Revise los datos del registro", errores)
    with transaccion() as cur:
        cur.sp("sp_usuario_registrar", usuario=limpio["usuario"], password=limpio["password"],
               nombre_completo=limpio["nombre_completo"], email=limpio.get("email")).fetchone()
    with transaccion() as cur:
        fila = cur.sp("sp_auth_login", usuario=limpio["usuario"], password=limpio["password"],
                      minutos=config.TOKEN_MINUTOS, ip=request.remote_addr).fetchone()
    resp, status = respuesta_login(fila)
    return resp, (201 if status == 200 else status)


@app.post("/api/auth/social")
def login_social():
    datos, err = leer_json()
    if err:
        return err
    limpio, errores = v.validar_social(datos, config.OAUTH_REDIRECT_URI)
    if errores:
        return error(400, "validacion", "Datos de inicio de sesión inválidos", errores)
    proveedor = limpio["proveedor"]
    if not auth.social_habilitado()[proveedor]:
        return error(400, "validacion", f"El inicio de sesión con {proveedor.title()} "
                                        "no está configurado en la API (.env)")
    try:
        if proveedor == "GOOGLE":
            perfil = auth.verificar_google(limpio["code"], limpio.get("code_verifier"))
        else:
            perfil = auth.verificar_facebook(limpio["code"])
    except auth.ErrorSocial as e:
        return error(401, "social", str(e))

    correo, _ = v.email(perfil.get("email"))
    respaldo = "Usuario Google" if proveedor == "GOOGLE" else "Usuario Facebook"
    with transaccion() as cur:
        fila = cur.sp("sp_auth_login_social", proveedor=proveedor,
                      proveedor_id=perfil["proveedor_id"], email=correo,
                      nombre_completo=v.nombre_para_bd(perfil.get("nombre"), respaldo),
                      usuario_sugerido=v.usuario_sugerido(correo, perfil.get("nombre"), proveedor),
                      minutos=config.TOKEN_MINUTOS, ip=request.remote_addr).fetchone()
    return respuesta_login(fila)


@app.post("/api/auth/logout")
@requiere_rol()
def logout():
    with transaccion() as cur:
        cur.sp("sp_auth_logout", token=g.token).fetchone()
    return ok({"mensaje": "Sesión cerrada"})


@app.get("/api/auth/yo")
@requiere_rol()
def yo():
    return ok({"usuario": serializar(g.usuario)})


# =====================================================================
# CATÁLOGO (todos los roles; el CLIENTE solo ve esto)
# =====================================================================
@app.get("/api/catalogo")
@requiere_rol()
def catalogo():
    q, err = v.validar_busqueda(request.args.get("q"))
    if err:
        return error(400, "validacion", err, {"q": err})
    pagina, tam, e = paginacion()
    if e:
        return error(400, "validacion", e)
    filtro, params = "", []
    if q:  # collation CI_AI: no distingue mayúsculas ni tildes
        filtro = "WHERE nombre_comercial LIKE ? OR principio_activo LIKE ? OR laboratorio LIKE ?"
        params = [f"%{q}%"] * 3
    with transaccion() as cur:
        total = cur.execute(f"SELECT COUNT(*) AS total FROM dbo.vw_catalogo {filtro}", params).fetchone()["total"]
        filas = cur.execute(
            f"SELECT * FROM dbo.vw_catalogo {filtro} ORDER BY nombre_comercial "
            "OFFSET ? ROWS FETCH NEXT ? ROWS ONLY", params + [(pagina - 1) * tam, tam]).fetchall()
    return ok({"datos": [serializar(f) for f in filas], "total": total, "pagina": pagina, "tam": tam})


@app.get("/api/catalogo/<int:mid>")
@requiere_rol()
def catalogo_detalle(mid):
    with transaccion() as cur:
        fila = cur.execute("SELECT * FROM dbo.vw_catalogo WHERE id = ?", [mid]).fetchone()
    if not fila:
        return error(404, "no_encontrado", "El medicamento no está disponible en el catálogo")
    return ok({"medicamento": serializar(fila)})


# =====================================================================
# MEDICAMENTOS (ADMIN y FARMACEUTICO ven todo; solo ADMIN modifica)
# =====================================================================
@app.get("/api/medicamentos")
@requiere_rol(*ROLES_PERSONAL)
def listar():
    q, err = v.validar_busqueda(request.args.get("q"))
    if err:
        return error(400, "validacion", err, {"q": err})

    filtros, params = [], []
    if q:
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

    pagina, tam, e = paginacion()
    if e:
        return error(400, "validacion", e)

    where = ("WHERE " + " AND ".join(filtros)) if filtros else ""
    with transaccion() as cur:
        total = cur.execute(f"SELECT COUNT(*) AS total FROM dbo.vw_medicamentos {where}", params).fetchone()["total"]
        filas = cur.execute(
            f"SELECT * FROM dbo.vw_medicamentos {where} ORDER BY id OFFSET ? ROWS FETCH NEXT ? ROWS ONLY",
            params + [(pagina - 1) * tam, tam]).fetchall()
    return ok({"datos": [serializar(f) for f in filas], "total": total, "pagina": pagina, "tam": tam})


@app.get("/api/medicamentos/alertas")
@requiere_rol(*ROLES_PERSONAL)
def alertas():
    with transaccion() as cur:
        filas = cur.execute("SELECT * FROM dbo.vw_medicamentos_alertas ORDER BY fecha_vencimiento").fetchall()
    return ok({"datos": [serializar(f) for f in filas], "total": len(filas)})


@app.get("/api/medicamentos/<int:mid>")
@requiere_rol(*ROLES_PERSONAL)
def obtener(mid):
    fila = leer_medicamento(mid)
    if not fila:
        return error(404, "no_encontrado", f"No existe el medicamento {mid}")
    return ok({"medicamento": serializar(fila)})


@app.get("/api/medicamentos/<int:mid>/movimientos")
@requiere_rol(*ROLES_PERSONAL)
def movimientos(mid):
    with transaccion() as cur:
        filas = cur.execute("SELECT TOP 50 * FROM dbo.vw_movimientos_stock WHERE medicamento_id = ? "
                            "ORDER BY fecha DESC, id DESC", [mid]).fetchall()
    return ok({"datos": [serializar(f) for f in filas], "total": len(filas)})


@app.post("/api/medicamentos")
@requiere_rol("ADMIN")
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
        nuevo = cur.sp("sp_medicamento_insertar", **limpio).fetchone()
    return ok({"mensaje": "Medicamento creado", "medicamento": serializar(nuevo)}, 201)


@app.put("/api/medicamentos/<int:mid>")
@requiere_rol("ADMIN")
def actualizar(mid):
    datos, err = leer_json()
    if err:
        return err
    limpio, errores = preparar_medicamento(datos, es_actualizacion=True)
    if errores:
        return error(400, "validacion", "Datos inválidos", errores)

    version = limpio.pop("version", None)
    try:
        vbytes = int_a_version(version)
    except (TypeError, ValueError, OverflowError):
        return error(400, "validacion", "version es obligatoria",
                     {"version": "Envíe la versión que leyó"})
    faltan = [c for c in v.CAMPOS_EDITABLES if c not in limpio]
    if faltan:
        return error(400, "validacion", "Faltan campos", {c: f"{c} es obligatorio" for c in faltan})

    def guardar():
        with transaccion() as cur:
            if not config.DESACTIVAR_VALIDACION_BACKEND:
                dup = buscar_duplicados(cur, limpio, excluir_id=mid)
                if dup:
                    return error(409, "duplicado", "Registro duplicado", dup)
            nuevo = cur.sp("sp_medicamento_actualizar", id=mid, version=vbytes, **limpio).fetchone()
        return ok({"mensaje": "Medicamento actualizado", "medicamento": serializar(nuevo)})

    return ejecutar_con_conflicto(guardar, lambda: leer_medicamento(mid))


@app.patch("/api/medicamentos/<int:mid>/stock")
@requiere_rol(*ROLES_PERSONAL)
def mover_stock(mid):
    """ENTRADA suma, SALIDA (despacho) resta. Endpoint de la prueba de
    concurrencia: N usuarios despachan a la vez y el stock NUNCA queda negativo."""
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

    def mover():
        with transaccion() as cur:
            fila = cur.sp("sp_medicamento_mover_stock", id=mid, operacion=mov["operacion"],
                          cantidad=mov["cantidad"], usuario_id=g.usuario["id"],
                          servidor=respuestas.SERVIDOR, demora_ms=demora).fetchone()
        anterior = fila.pop("stock_anterior")
        return ok({"mensaje": f"{mov['operacion']} de {mov['cantidad']} unidad(es) registrada",
                   "stock_anterior": anterior, "medicamento": serializar(fila)})

    return ejecutar_con_conflicto(mover, lambda: leer_medicamento(mid))


@app.delete("/api/medicamentos/<int:mid>")
@requiere_rol("ADMIN")
def eliminar(mid):
    """Baja LÓGICA (estado = INACTIVO). Exige ?version=N."""
    version, e = v.entero(request.args.get("version", ""), "version", 1, 2**63 - 1)
    if e:
        return error(400, "validacion", "Envíe ?version= con la versión que leyó")

    def baja():
        with transaccion() as cur:
            fila = cur.sp("sp_medicamento_baja", id=mid, version=int_a_version(version)).fetchone()
        return ok({"mensaje": "Medicamento dado de baja (INACTIVO)", "medicamento": serializar(fila)})

    return ejecutar_con_conflicto(baja, lambda: leer_medicamento(mid))


# =====================================================================
# USUARIOS (solo ADMIN)
# =====================================================================
@app.get("/api/usuarios")
@requiere_rol("ADMIN")
def listar_usuarios():
    q = (request.args.get("q") or "").strip()
    if q and not re.fullmatch(rf"[{v.LETRA}0-9 ._@+-]{{1,50}}", q):
        return error(400, "validacion", "Búsqueda inválida")
    rol = (request.args.get("rol") or "").strip().upper()
    if rol and rol not in v.ROLES:
        return error(400, "validacion", "Rol no válido")
    filtros, params = [], []
    if q:
        filtros.append("(usuario LIKE ? OR nombre_completo LIKE ? OR email LIKE ?)")
        params += [f"%{q}%"] * 3
    if rol:
        filtros.append("rol = ?")
        params.append(rol)
    where = ("WHERE " + " AND ".join(filtros)) if filtros else ""
    with transaccion() as cur:
        filas = cur.execute(f"SELECT * FROM dbo.vw_usuarios {where} ORDER BY rol, usuario", params).fetchall()
    return ok({"datos": [serializar(f) for f in filas], "total": len(filas)})


@app.post("/api/usuarios")
@requiere_rol("ADMIN")
def crear_usuario():
    datos, err = leer_json()
    if err:
        return err
    limpio, errores = v.validar_usuario_admin(datos)
    if errores:
        return error(400, "validacion", "Datos inválidos", errores)
    with transaccion() as cur:
        nuevo = cur.sp("sp_usuario_crear", usuario=limpio["usuario"], password=limpio["password"],
                       nombre_completo=limpio["nombre_completo"], email=limpio.get("email"),
                       rol=limpio["rol"], estado=limpio.get("estado", True)).fetchone()
    return ok({"mensaje": "Usuario creado", "usuario": serializar(nuevo)}, 201)


@app.put("/api/usuarios/<int:uid>")
@requiere_rol("ADMIN")
def actualizar_usuario(uid):
    datos, err = leer_json()
    if err:
        return err
    limpio, errores = v.validar_usuario_admin(datos, es_actualizacion=True)
    if errores:
        return error(400, "validacion", "Datos inválidos", errores)

    def guardar():
        with transaccion() as cur:
            fila = cur.sp("sp_usuario_actualizar", id=uid,
                          nombre_completo=limpio["nombre_completo"], email=limpio.get("email"),
                          rol=limpio["rol"], estado=limpio["estado"],
                          version=int_a_version(limpio["version"]),
                          password=limpio.get("password"),
                          desbloquear=limpio.get("desbloquear", False),
                          admin_id=g.usuario["id"]).fetchone()
        return ok({"mensaje": "Usuario actualizado", "usuario": serializar(fila)})

    return ejecutar_con_conflicto(guardar, lambda: leer_usuario(uid), clave="usuario")


# =====================================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="API Farmacia")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--nombre", help="Nombre del servidor (cabecera X-Server)")
    args = parser.parse_args()

    respuestas.SERVIDOR = args.nombre or f"flask-{args.port}"
    print(f" * {respuestas.SERVIDOR} -> SQL Server {config.DB_SERVER} / {config.DB_DATABASE}")
    print(f" * Token: {config.TOKEN_MINUTOS} min · Google: "
          f"{'sí' if auth.social_habilitado()['GOOGLE'] else 'no'} · Facebook: "
          f"{'sí' if auth.social_habilitado()['FACEBOOK'] else 'no'}")
    if config.DESACTIVAR_VALIDACION_BACKEND:
        print(" * ATENCIÓN: validación del backend DESACTIVADA (solo controla la BD)")
    # threaded=True: atiende varias peticiones a la vez (necesario para concurrencia)
    app.run(host=args.host, port=args.port, threaded=True, debug=False)
