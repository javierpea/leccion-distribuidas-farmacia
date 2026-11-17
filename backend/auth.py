"""
Autenticación con token y permisos por rol (Unidad 3 - Práctica Final).

  - POST /api/auth/login devuelve un token temporal (TOKEN_MINUTOS).
  - Cada petición protegida envía:  Authorization: Bearer <token>
  - La API valida el token en la BD (sp_auth_validar_token) y revisa el
    rol del usuario:

        Acción                                   ADMIN  FARMACEUTICO  CLIENTE
        Catálogo y detalle (solo ACTIVOS)          ✔        ✔           ✔
        Ver todos los medicamentos y alertas       ✔        ✔
        Despachar / ingresar stock                 ✔        ✔
        Crear, editar y dar de baja                ✔
        Gestionar usuarios y roles                 ✔

  - Sin token, token falso o vencido -> 401 (la app vuelve al login con
    "Sesión expirada").  Rol sin permiso -> 403.

Login con Google / Facebook (OAuth 2.0 "authorization code"):
  la app abre el navegador, el usuario acepta y el proveedor devuelve un
  "code" a http://localhost:8765/callback. La app manda ese code a la API
  y la API (que tiene el secreto) lo canjea y verifica la identidad.
"""
import hashlib
import hmac
from functools import wraps

import requests
from flask import g, request

import config
import validators as v
from db import transaccion
from respuestas import error

ROLES_PERSONAL = ("ADMIN", "FARMACEUTICO")


def token_de_peticion():
    """None = no envió token · '' = formato inválido · str = token."""
    cabecera = request.headers.get("Authorization", "")
    if not cabecera.startswith("Bearer "):
        return None
    token = cabecera[7:].strip()
    return token if v.RE_TOKEN.match(token) else ""


def requiere_rol(*roles):
    """@requiere_rol()                      -> cualquier usuario con sesión
       @requiere_rol("ADMIN")               -> solo administradores
       @requiere_rol("ADMIN", "FARMACEUTICO")"""
    def decorador(funcion):
        @wraps(funcion)
        def envoltura(*args, **kwargs):
            token = token_de_peticion()
            if token is None:
                return error(401, "sin_token", "Token no enviado. Inicie sesión.")
            if token == "":
                return error(401, "token_invalido", "Token inválido. Inicie sesión de nuevo.")
            with transaccion() as cur:
                usuario = cur.sp("sp_auth_validar_token", token=token).fetchone()
            if not usuario:
                return error(401, "sesion_expirada",
                             "Sesión expirada. Inicie sesión de nuevo.")
            if roles and usuario["rol"] not in roles:
                return error(403, "sin_permiso",
                             f"Su rol ({usuario['rol']}) no tiene permiso para esta acción")
            g.usuario = usuario
            g.token = token
            return funcion(*args, **kwargs)
        return envoltura
    return decorador


# =====================================================================
# Google y Facebook
# =====================================================================
class ErrorSocial(Exception):
    pass


def social_habilitado():
    return {
        "GOOGLE": bool(config.GOOGLE_CLIENT_ID and config.GOOGLE_CLIENT_SECRET),
        "FACEBOOK": bool(config.FACEBOOK_APP_ID and config.FACEBOOK_APP_SECRET),
    }


def verificar_google(code, code_verifier):
    """Canjea el code por un id_token y lo verifica con Google."""
    datos = {
        "code": code,
        "client_id": config.GOOGLE_CLIENT_ID,
        "client_secret": config.GOOGLE_CLIENT_SECRET,
        "redirect_uri": config.OAUTH_REDIRECT_URI,
        "grant_type": "authorization_code",
    }
    if code_verifier:
        datos["code_verifier"] = code_verifier
    try:
        r = requests.post("https://oauth2.googleapis.com/token", data=datos, timeout=10)
        if not r.ok:
            raise ErrorSocial("Google rechazó el inicio de sesión. Intente de nuevo.")
        id_token = r.json().get("id_token")
        info = requests.get("https://oauth2.googleapis.com/tokeninfo",
                            params={"id_token": id_token}, timeout=10).json()
    except requests.RequestException:
        raise ErrorSocial("No se pudo contactar a Google desde el servidor")

    if info.get("aud") != config.GOOGLE_CLIENT_ID or \
            info.get("iss") not in ("accounts.google.com", "https://accounts.google.com"):
        raise ErrorSocial("La respuesta de Google no es válida para esta aplicación")
    correo = info.get("email") if str(info.get("email_verified")).lower() == "true" else None
    return {"proveedor_id": str(info["sub"]), "email": correo, "nombre": info.get("name")}


def verificar_facebook(code):
    """Canjea el code por un access_token y pide id, nombre y correo."""
    try:
        r = requests.get("https://graph.facebook.com/oauth/access_token", params={
            "client_id": config.FACEBOOK_APP_ID,
            "client_secret": config.FACEBOOK_APP_SECRET,
            "redirect_uri": config.OAUTH_REDIRECT_URI,
            "code": code,
        }, timeout=10)
        if not r.ok:
            raise ErrorSocial("Facebook rechazó el inicio de sesión. Intente de nuevo.")
        acceso = r.json()["access_token"]
        # appsecret_proof: demuestra que la llamada la hace NUESTRO servidor
        prueba = hmac.new(config.FACEBOOK_APP_SECRET.encode(), acceso.encode(),
                          hashlib.sha256).hexdigest()
        info = requests.get("https://graph.facebook.com/me", params={
            "fields": "id,name,email", "access_token": acceso, "appsecret_proof": prueba,
        }, timeout=10).json()
    except (requests.RequestException, KeyError, ValueError):
        raise ErrorSocial("No se pudo verificar la cuenta con Facebook")
    if "id" not in info:
        raise ErrorSocial("Facebook no devolvió la identidad del usuario")
    return {"proveedor_id": str(info["id"]), "email": info.get("email"), "nombre": info.get("name")}
