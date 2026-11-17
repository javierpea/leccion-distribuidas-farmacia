"""
Controles del BACKEND (primera línea de defensa).

Son los MISMOS que tiene la base de datos (CHECK + UNIQUE + trigger).
Si alguien se salta la API (o se desactiva esta validación), la BD los
vuelve a aplicar. Si la BD se configurara mal, la API igual los aplica.
"""
import math
import re
import unicodedata
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

# ---------------------------------------------------------------------
# Expresiones regulares (idénticas a las de 01_schema.sql)
# ---------------------------------------------------------------------
LETRA = "A-Za-zÁÉÍÓÚÜÑáéíóúüñ"
RE_SOLO_LETRAS = re.compile(rf"^[{LETRA}]+( [{LETRA}]+)*$")
RE_CODIGO = re.compile(r"^MED-[0-9]{4}$")
RE_CONCENTRACION = re.compile(
    r"^[0-9]{1,5}(\.[0-9]{1,3})? ?(mg|g|mcg|ml|UI|%)(/[0-9]{0,4} ?(ml|g))?$")
RE_REGISTRO = re.compile(r"^[A-Z0-9]{2,8}(-[A-Z0-9]{2,8}){0,3}$")
RE_LOTE = re.compile(r"^[A-Z0-9]{3,10}(-[A-Z0-9]{1,8})?$")
RE_ENTERO = re.compile(r"^[0-9]+$")
RE_DECIMAL = re.compile(r"^[0-9]{1,5}(\.[0-9]{1,2})?$")
RE_FECHA = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
RE_BUSQUEDA = re.compile(rf"^[{LETRA}0-9 \-]{{1,50}}$")

FORMAS = {"TABLETA", "CAPSULA", "JARABE", "SUSPENSION",
          "INYECTABLE", "CREMA", "GOTAS", "POLVO"}
ESTADOS = {"ACTIVO", "INACTIVO", "VENCIDO", "RETIRADO"}
OPERACIONES_STOCK = {"ENTRADA", "SALIDA"}

STOCK_MAX = 100_000
STOCK_MINIMO_MAX = 10_000
PRECIO_MAX = Decimal("99999.99")
MOVIMIENTO_MAX = 10_000

# Campos que el cliente puede enviar
CAMPOS_EDITABLES = [
    "nombre_comercial", "principio_activo", "laboratorio", "concentracion",
    "forma_farmaceutica", "registro_sanitario", "lote",
    "fecha_fabricacion", "fecha_vencimiento",
    "stock", "stock_minimo", "precio_compra", "precio_venta",
    "requiere_receta", "estado",
]
CAMPOS_CREAR = ["codigo"] + CAMPOS_EDITABLES
CAMPOS_ACTUALIZAR = CAMPOS_EDITABLES + ["version", "codigo"]

OPCIONALES = {"stock_minimo": 10, "requiere_receta": False, "estado": "ACTIVO"}


# ---------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------
def limpiar_espacios(texto: str) -> str:
    return re.sub(r"\s+", " ", texto.strip())


def normalizar_nombre(texto: str) -> str:
    """Igual que fn_normalizar_nombre() de la BD: minúsculas, sin tildes,
    espacios simples. 'PARACETÁMOL  Genfar' == 'paracetamol genfar'."""
    sin_tildes = "".join(
        c for c in unicodedata.normalize("NFD", texto.lower())
        if unicodedata.category(c) != "Mn"  # quita tildes (ñ -> n, igual que la BD)
    )
    return limpiar_espacios(sin_tildes)


def _es_numero_json(valor) -> bool:
    # En Python bool es subclase de int: True no debe pasar como 1
    return isinstance(valor, (int, float)) and not isinstance(valor, bool)


# ---------------------------------------------------------------------
# Validadores por tipo. Cada uno devuelve (valor_limpio, error | None)
# ---------------------------------------------------------------------
def texto_solo_letras(valor, campo, minimo, maximo):
    if not isinstance(valor, str):
        return None, f"{campo} debe ser texto"
    v = limpiar_espacios(valor)
    if not v:
        return None, f"{campo} es obligatorio"
    if any(c.isdigit() for c in v):
        return None, f"{campo} no puede contener números"
    if not RE_SOLO_LETRAS.match(v):
        return None, f"{campo} solo admite letras y espacios (sin símbolos)"
    if not (minimo <= len(v) <= maximo):
        return None, f"{campo} debe tener entre {minimo} y {maximo} caracteres"
    return v, None


def texto_con_formato(valor, campo, regex, ejemplo, mayusculas=True):
    if not isinstance(valor, str):
        return None, f"{campo} debe ser texto"
    v = limpiar_espacios(valor)
    if mayusculas:
        v = v.upper()
    if not v:
        return None, f"{campo} es obligatorio"
    if not regex.match(v):
        return None, f"{campo} tiene formato inválido (ejemplo: {ejemplo})"
    return v, None


def entero(valor, campo, minimo, maximo):
    if isinstance(valor, bool):
        return None, f"{campo} debe ser un número entero"
    if isinstance(valor, float):
        if not valor.is_integer():
            return None, f"{campo} debe ser un número entero (sin decimales)"
        valor = int(valor)
    if isinstance(valor, str):
        v = valor.strip()
        if v.startswith("-") and RE_ENTERO.match(v[1:]):
            return None, f"{campo} no puede ser negativo"
        if not RE_ENTERO.match(v):
            return None, f"{campo} solo admite números enteros"
        valor = int(v)
    if not isinstance(valor, int):
        return None, f"{campo} debe ser un número entero"
    if valor < 0:
        return None, f"{campo} no puede ser negativo"
    if not (minimo <= valor <= maximo):
        return None, f"{campo} debe estar entre {minimo} y {maximo}"
    return valor, None


def decimal_positivo(valor, campo, maximo=PRECIO_MAX):
    if isinstance(valor, bool) or valor is None:
        return None, f"{campo} debe ser un número"
    if _es_numero_json(valor):
        if isinstance(valor, float) and (math.isnan(valor) or math.isinf(valor)):
            return None, f"{campo} debe ser un número válido"
        texto = repr(valor) if isinstance(valor, float) else str(valor)
    elif isinstance(valor, str):
        texto = valor.strip().replace(",", ".")
    else:
        return None, f"{campo} debe ser un número"

    if texto.startswith("-"):
        return None, f"{campo} no puede ser negativo"
    try:
        d = Decimal(texto)
    except InvalidOperation:
        return None, f"{campo} solo admite números (ejemplo: 12.50)"
    if not d.is_finite():
        return None, f"{campo} debe ser un número válido"
    if d.as_tuple().exponent < -2:
        return None, f"{campo} admite máximo 2 decimales"
    if d <= 0:
        return None, f"{campo} debe ser mayor a 0"
    if d > maximo:
        return None, f"{campo} no puede superar {maximo}"
    return d.quantize(Decimal("0.01")), None


def fecha(valor, campo):
    if not isinstance(valor, str) or not RE_FECHA.match(valor.strip()):
        return None, f"{campo} debe tener formato AAAA-MM-DD"
    try:
        return datetime.strptime(valor.strip(), "%Y-%m-%d").date(), None
    except ValueError:
        return None, f"{campo} no es una fecha válida"


def booleano(valor, campo):
    if isinstance(valor, bool):
        return valor, None
    return None, f"{campo} debe ser true o false"


def opcion(valor, campo, opciones):
    if not isinstance(valor, str):
        return None, f"{campo} debe ser texto"
    v = valor.strip().upper()
    if v not in opciones:
        return None, f"{campo} debe ser uno de: {', '.join(sorted(opciones))}"
    return v, None


# ---------------------------------------------------------------------
# Validación completa de un medicamento
# ---------------------------------------------------------------------
VALIDADORES = {
    "codigo": lambda v: texto_con_formato(v, "codigo", RE_CODIGO, "MED-0001"),
    "nombre_comercial": lambda v: texto_solo_letras(v, "nombre_comercial", 3, 100),
    "principio_activo": lambda v: texto_solo_letras(v, "principio_activo", 3, 100),
    "laboratorio": lambda v: texto_solo_letras(v, "laboratorio", 2, 80),
    "concentracion": lambda v: texto_con_formato(
        v.lower().replace("ui", "UI") if isinstance(v, str) else v,
        "concentracion", RE_CONCENTRACION, "500 mg, 250 mg/5 ml", mayusculas=False),
    "forma_farmaceutica": lambda v: opcion(v, "forma_farmaceutica", FORMAS),
    "registro_sanitario": lambda v: texto_con_formato(
        v, "registro_sanitario", RE_REGISTRO, "1234-MEE-0521"),
    "lote": lambda v: texto_con_formato(v, "lote", RE_LOTE, "L2026A01"),
    "fecha_fabricacion": lambda v: fecha(v, "fecha_fabricacion"),
    "fecha_vencimiento": lambda v: fecha(v, "fecha_vencimiento"),
    "stock": lambda v: entero(v, "stock", 0, STOCK_MAX),
    "stock_minimo": lambda v: entero(v, "stock_minimo", 0, STOCK_MINIMO_MAX),
    "precio_compra": lambda v: decimal_positivo(v, "precio_compra"),
    "precio_venta": lambda v: decimal_positivo(v, "precio_venta"),
    "requiere_receta": lambda v: booleano(v, "requiere_receta"),
    "estado": lambda v: opcion(v, "estado", ESTADOS),
    "version": lambda v: entero(v, "version", 1, 2**63 - 1),
}


def validar_medicamento(datos, es_actualizacion=False, hoy=None):
    """Devuelve (datos_limpios, errores). errores = {campo: mensaje}."""
    hoy = hoy or date.today()
    errores = {}

    if not isinstance(datos, dict):
        return {}, {"_general": "El cuerpo debe ser un objeto JSON"}

    permitidos = CAMPOS_ACTUALIZAR if es_actualizacion else CAMPOS_CREAR
    for campo in datos:
        if campo not in permitidos:
            errores[campo] = "Campo no permitido"

    requeridos = [c for c in permitidos if c not in OPCIONALES]
    if es_actualizacion:
        requeridos = [c for c in requeridos if c != "codigo"]

    limpio = {}
    for campo in permitidos:
        if campo not in datos or datos[campo] is None:
            if campo in requeridos:
                errores[campo] = f"{campo} es obligatorio"
            elif campo in OPCIONALES and not es_actualizacion:
                limpio[campo] = OPCIONALES[campo]
            continue
        valor, error = VALIDADORES[campo](datos[campo])
        if error:
            errores[campo] = error
        else:
            limpio[campo] = valor

    # ---------- Reglas entre campos ----------
    fab, ven = limpio.get("fecha_fabricacion"), limpio.get("fecha_vencimiento")
    if fab and fab > hoy:
        errores["fecha_fabricacion"] = "La fecha de fabricación no puede ser futura"
    if fab and ven and ven <= fab:
        errores["fecha_vencimiento"] = "Debe ser posterior a la fecha de fabricación"
    if ven and not es_actualizacion and ven <= hoy:
        errores["fecha_vencimiento"] = "No se puede registrar un medicamento vencido"

    pc, pv = limpio.get("precio_compra"), limpio.get("precio_venta")
    if pc is not None and pv is not None and pv < pc:
        errores["precio_venta"] = "El precio de venta no puede ser menor al de compra"

    return limpio, errores


def validar_movimiento_stock(datos):
    if not isinstance(datos, dict):
        return {}, {"_general": "El cuerpo debe ser un objeto JSON"}
    errores, limpio = {}, {}
    for campo in datos:
        if campo not in ("operacion", "cantidad"):
            errores[campo] = "Campo no permitido"

    op, err = opcion(datos.get("operacion"), "operacion", OPERACIONES_STOCK) \
        if datos.get("operacion") is not None else (None, "operacion es obligatoria")
    if err:
        errores["operacion"] = err
    else:
        limpio["operacion"] = op

    if datos.get("cantidad") is None:
        errores["cantidad"] = "cantidad es obligatoria"
    else:
        cant, err = entero(datos["cantidad"], "cantidad", 1, MOVIMIENTO_MAX)
        if err:
            errores["cantidad"] = err
        else:
            limpio["cantidad"] = cant
    return limpio, errores


def validar_busqueda(texto):
    if texto is None or texto.strip() == "":
        return None, None
    if not RE_BUSQUEDA.match(texto.strip()):
        return None, "La búsqueda solo admite letras, números, espacios y guion (máx. 50)"
    return texto.strip(), None


# =====================================================================
# USUARIOS Y LOGIN (mismas reglas que dbo.usuarios en 01_schema.sql)
# =====================================================================
RE_USUARIO = re.compile(r"^[a-z][a-z0-9._]{3,29}$")
RE_EMAIL = re.compile(r"^[a-z0-9._+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$")
RE_TOKEN = re.compile(r"^[0-9A-F]{64}$")
RE_CODE_VERIFIER = re.compile(r"^[A-Za-z0-9\-._~]{43,128}$")
ROLES = {"ADMIN", "FARMACEUTICO", "CLIENTE"}
PROVEEDORES_SOCIALES = {"GOOGLE", "FACEBOOK"}


def usuario(valor):
    if not isinstance(valor, str):
        return None, "usuario debe ser texto"
    v = valor.strip().lower()
    if not v:
        return None, "usuario es obligatorio"
    if not RE_USUARIO.match(v):
        return None, ("usuario: 4 a 30 caracteres, empieza con letra; solo minúsculas, "
                      "números, punto y guion bajo")
    return v, None


def password(valor):
    if not isinstance(valor, str) or not valor:
        return None, "La contraseña es obligatoria"
    if " " in valor:
        return None, "La contraseña no puede tener espacios"
    if not (8 <= len(valor) <= 50):
        return None, "La contraseña debe tener entre 8 y 50 caracteres"
    if not re.search(r"[A-Za-z]", valor) or not re.search(r"[0-9]", valor):
        return None, "La contraseña debe tener letras y números"
    return valor, None


def email(valor):
    if valor is None or (isinstance(valor, str) and valor.strip() == ""):
        return None, None  # opcional
    if not isinstance(valor, str):
        return None, "email debe ser texto"
    v = valor.strip().lower()
    if len(v) > 100 or not RE_EMAIL.match(v) or ".." in v:
        return None, "Correo inválido (ejemplo: nombre@correo.com)"
    return v, None


def _validar_campos(datos, permitidos, requeridos, validadores):
    if not isinstance(datos, dict):
        return {}, {"_general": "El cuerpo debe ser un objeto JSON"}
    errores, limpio = {}, {}
    for campo in datos:
        if campo not in permitidos:
            errores[campo] = "Campo no permitido"
    for campo in permitidos:
        valor = datos.get(campo)
        if valor is None or (isinstance(valor, str) and valor.strip() == "" and campo != "email"):
            if campo in requeridos:
                errores[campo] = f"{campo} es obligatorio"
            continue
        limpio_valor, error = validadores[campo](valor)
        if error:
            errores[campo] = error
        elif limpio_valor is not None:
            limpio[campo] = limpio_valor
    return limpio, errores


VALIDADORES_USUARIO = {
    "usuario": usuario,
    "password": password,
    "nombre_completo": lambda v: texto_solo_letras(v, "nombre_completo", 3, 100),
    "email": email,
    "rol": lambda v: opcion(v, "rol", ROLES),
    "estado": lambda v: booleano(v, "estado"),
    "desbloquear": lambda v: booleano(v, "desbloquear"),
    "version": lambda v: entero(v, "version", 1, 2**63 - 1),
}


def validar_login(datos):
    """No revela las reglas: solo que vengan los dos campos."""
    if not isinstance(datos, dict):
        return {}, {"_general": "El cuerpo debe ser un objeto JSON"}
    errores = {}
    u, p = datos.get("usuario"), datos.get("password")
    if not isinstance(u, str) or not u.strip() or len(u.strip()) > 100:
        errores["usuario"] = "Ingrese su usuario o correo"
    if not isinstance(p, str) or not p or len(p) > 100:
        errores["password"] = "Ingrese su contraseña"
    if errores:
        return {}, errores
    return {"usuario": u.strip().lower(), "password": p}, {}


def validar_registro(datos):
    return _validar_campos(datos, ["usuario", "password", "nombre_completo", "email"],
                           ["usuario", "password", "nombre_completo"], VALIDADORES_USUARIO)


def validar_usuario_admin(datos, es_actualizacion=False):
    if es_actualizacion:
        permitidos = ["nombre_completo", "email", "rol", "estado", "version",
                      "password", "desbloquear"]
        requeridos = ["nombre_completo", "rol", "estado", "version"]
    else:
        permitidos = ["usuario", "password", "nombre_completo", "email", "rol", "estado"]
        requeridos = ["usuario", "password", "nombre_completo", "rol"]
    return _validar_campos(datos, permitidos, requeridos, VALIDADORES_USUARIO)


def validar_social(datos, redirect_uri):
    if not isinstance(datos, dict):
        return {}, {"_general": "El cuerpo debe ser un objeto JSON"}
    errores, limpio = {}, {}
    prov, err = opcion(datos.get("proveedor") or "", "proveedor", PROVEEDORES_SOCIALES)
    if err:
        errores["proveedor"] = err
    else:
        limpio["proveedor"] = prov
    code = datos.get("code")
    if not isinstance(code, str) or not (10 <= len(code) <= 2048) or any(c.isspace() for c in code):
        errores["code"] = "Código de autorización inválido"
    else:
        limpio["code"] = code
    verificador = datos.get("code_verifier")
    if verificador is not None:
        if not isinstance(verificador, str) or not RE_CODE_VERIFIER.match(verificador):
            errores["code_verifier"] = "code_verifier inválido"
        else:
            limpio["code_verifier"] = verificador
    if datos.get("redirect_uri") != redirect_uri:
        errores["redirect_uri"] = "redirect_uri no coincide con la configuración de la API"
    return limpio, errores


def nombre_para_bd(texto, respaldo):
    """Deja solo letras y espacios (los nombres de Google/Facebook pueden
    traer números, guiones o emojis que la BD rechazaría)."""
    limpio = re.sub(rf"[^{LETRA} ]", " ", texto or "")
    limpio = limpiar_espacios(limpio)[:100].strip()
    return limpio if len(limpio) >= 3 else respaldo


def usuario_sugerido(email_valor, nombre, proveedor):
    """juan.perez@gmail.com -> 'juan.perez'. La BD agrega 2, 3... si ya existe."""
    base = (email_valor or "").split("@")[0] or normalizar_nombre(nombre or "").replace(" ", ".")
    base = re.sub(r"[^a-z0-9._]", "", normalizar_nombre(base).replace(" ", "."))
    base = base.strip("._")
    if not base or not base[0].isalpha():
        base = proveedor.lower() + base
    if len(base) < 4:
        base += "user"
    return base[:25]
