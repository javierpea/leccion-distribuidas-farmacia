"""
Pruebas de los controles del backend (no necesitan base de datos).
    cd backend
    python -m unittest discover -s tests -v
"""
import os
import sys
import unittest
from contextlib import contextmanager
from datetime import date
from unittest import mock
from decimal import Decimal

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pyodbc  # noqa: E402

import app as app_mod  # noqa: E402
import auth  # noqa: E402
import validators as v  # noqa: E402
from app import app  # noqa: E402

HOY = date(2026, 11, 16)

BASE = {
    "codigo": "MED-0999",
    "nombre_comercial": "Producto Prueba",
    "principio_activo": "Paracetamol",
    "laboratorio": "Genfar",
    "concentracion": "500 mg",
    "forma_farmaceutica": "TABLETA",
    "registro_sanitario": "9999-PRB-01",
    "lote": "LPRB01",
    "fecha_fabricacion": "2026-01-01",
    "fecha_vencimiento": "2029-01-01",
    "stock": 5,
    "precio_compra": 1.0,
    "precio_venta": 2.0,
}


def errores(**cambios):
    datos = {**BASE, **cambios}
    return v.validar_medicamento(datos, hoy=HOY)[1]


class TestValidadores(unittest.TestCase):
    def test_datos_validos(self):
        limpio, err = v.validar_medicamento(dict(BASE), hoy=HOY)
        self.assertEqual(err, {})
        self.assertEqual(limpio["precio_venta"], Decimal("2.00"))
        self.assertEqual(limpio["estado"], "ACTIVO")  # valor por defecto

    def test_stock_negativo_texto_decimal_booleano(self):
        self.assertIn("negativo", errores(stock=-5)["stock"])
        self.assertIn("negativo", errores(stock="-5")["stock"])
        self.assertIn("stock", errores(stock="diez"))
        self.assertIn("stock", errores(stock=2.5))
        self.assertIn("stock", errores(stock=True))
        self.assertNotIn("stock", errores(stock="7"))

    def test_precios(self):
        self.assertIn("precio_compra", errores(precio_compra=0))
        self.assertIn("precio_compra", errores(precio_compra=-1))
        self.assertIn("precio_venta", errores(precio_venta="12abc"))
        self.assertIn("precio_venta", errores(precio_venta=1.234))
        self.assertIn("precio_venta", errores(precio_venta=float("nan")))
        self.assertIn("precio_venta", errores(precio_compra=5, precio_venta=1))

    def test_texto_solo_letras(self):
        self.assertIn("números", errores(nombre_comercial="Paracetamol 500")["nombre_comercial"])
        self.assertIn("nombre_comercial", errores(nombre_comercial="Para<script>"))
        self.assertIn("nombre_comercial", errores(nombre_comercial="ab"))
        self.assertIn("nombre_comercial", errores(nombre_comercial=123))
        self.assertNotIn("nombre_comercial", errores(nombre_comercial="  Ácido   Fólico Ñandú "))
        self.assertIn("laboratorio", errores(laboratorio="Lab 3"))

    def test_codigos_alfanumericos(self):
        self.assertIn("codigo", errores(codigo="ABC"))
        self.assertNotIn("codigo", errores(codigo="med-0001"))  # se pasa a mayúsculas
        self.assertIn("lote", errores(lote="L 2026"))
        self.assertIn("registro_sanitario", errores(registro_sanitario="12/34"))

    def test_concentracion(self):
        for ok in ["500 mg", "250 mg/5 ml", "10 mg/ml", "1 %", "100 mcg", "500 MG", "1000 UI"]:
            self.assertNotIn("concentracion", errores(concentracion=ok), ok)
        self.assertIn("concentracion", errores(concentracion="mucho"))

    def test_fechas(self):
        self.assertIn("fecha_vencimiento", errores(fecha_vencimiento="2020-01-01"))
        self.assertIn("fecha_fabricacion", errores(fecha_fabricacion="2027-01-01"))
        self.assertIn("fecha_fabricacion", errores(fecha_fabricacion="2026-02-30"))
        self.assertIn("fecha_fabricacion", errores(fecha_fabricacion="01/01/2026"))

    def test_campos_no_permitidos_y_obligatorios(self):
        self.assertIn("version", errores(version=5))  # no se permite en POST
        self.assertIn("id", errores(id=1))
        datos = dict(BASE)
        del datos["stock"]
        self.assertIn("stock", v.validar_medicamento(datos, hoy=HOY)[1])

    def test_nombre_normalizado(self):
        self.assertEqual(v.normalizar_nombre("  PARACETÁMOL   Genfar "), "paracetamol genfar")
        self.assertEqual(v.normalizar_nombre("Piña"), "pina")

    def test_movimiento_stock(self):
        self.assertEqual(v.validar_movimiento_stock({"operacion": "salida", "cantidad": 3})[1], {})
        self.assertIn("cantidad", v.validar_movimiento_stock({"operacion": "SALIDA", "cantidad": 0})[1])
        self.assertIn("cantidad", v.validar_movimiento_stock({"operacion": "SALIDA", "cantidad": -2})[1])
        self.assertIn("operacion", v.validar_movimiento_stock({"operacion": "ROBAR", "cantidad": 1})[1])


# ---------------------------------------------------------------------
# Simulación de la BD para probar tokens y roles sin SQL Server
# ---------------------------------------------------------------------
TOKENS = {"A" * 64: "ADMIN", "B" * 64: "FARMACEUTICO", "C" * 64: "CLIENTE"}


class _FilaFalsa:
    def __init__(self, fila):
        self.fila = fila

    def fetchone(self):
        return self.fila


class _CursorFalso:
    def sp(self, nombre, **p):
        assert nombre == "sp_auth_validar_token"
        rol = TOKENS.get(p["token"])
        return _FilaFalsa({"id": 1, "usuario": rol.lower(), "rol": rol} if rol else None)


@contextmanager
def _transaccion_falsa():
    yield _CursorFalso()


def cab(token):
    return {"Authorization": f"Bearer {token}"}


ADMIN, FARMA, CLIENTE = (cab(t) for t in TOKENS)


class TestApiSinBD(unittest.TestCase):
    """Peticiones que el backend rechaza ANTES de llegar a la BD."""

    def setUp(self):
        self.c = app.test_client()
        parche = mock.patch.object(auth, "transaccion", _transaccion_falsa)
        parche.start()
        self.addCleanup(parche.stop)

    # ---------------- token y roles ----------------
    def test_sin_token_401(self):
        r = self.c.get("/api/catalogo")
        self.assertEqual(r.status_code, 401)
        self.assertEqual(r.get_json()["motivo"], "sin_token")

    def test_token_inventado_401(self):
        self.assertEqual(self.c.get("/api/catalogo", headers=cab("F" * 64)).status_code, 401)
        self.assertEqual(self.c.get("/api/catalogo", headers=cab("abc")).status_code, 401)

    def test_cliente_no_puede_crud_403(self):
        self.assertEqual(self.c.post("/api/medicamentos", json=BASE, headers=CLIENTE).status_code, 403)
        self.assertEqual(self.c.get("/api/medicamentos", headers=CLIENTE).status_code, 403)
        self.assertEqual(self.c.get("/api/usuarios", headers=CLIENTE).status_code, 403)
        r = self.c.patch("/api/medicamentos/1/stock", json={"operacion": "SALIDA", "cantidad": 1},
                         headers=CLIENTE)
        self.assertEqual(r.status_code, 403)

    def test_farmaceutico_no_crea_ni_borra_403(self):
        self.assertEqual(self.c.post("/api/medicamentos", json=BASE, headers=FARMA).status_code, 403)
        self.assertEqual(self.c.delete("/api/medicamentos/1?version=5", headers=FARMA).status_code, 403)
        self.assertEqual(self.c.put("/api/usuarios/1", json={}, headers=FARMA).status_code, 403)

    def test_farmaceutico_si_mueve_stock(self):
        # pasa el permiso y lo detiene la validación (cantidad negativa)
        r = self.c.patch("/api/medicamentos/1/stock", json={"operacion": "SALIDA", "cantidad": -3},
                         headers=FARMA)
        self.assertEqual(r.status_code, 400)

    def test_registro_valida_campos(self):
        r = self.c.post("/api/auth/registro", json={"usuario": "J", "password": "123",
                                                    "nombre_completo": "Juan 2", "email": "x@"})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(set(r.get_json()["errores"]), {"usuario", "password", "nombre_completo", "email"})

    def test_registro_no_acepta_rol(self):
        r = self.c.post("/api/auth/registro", json={"usuario": "juan.perez", "password": "Clave123",
                                                    "nombre_completo": "Juan Perez", "rol": "ADMIN"})
        self.assertEqual(r.status_code, 400)
        self.assertIn("rol", r.get_json()["errores"])

    def test_login_sin_campos(self):
        self.assertEqual(self.c.post("/api/auth/login", json={}).status_code, 400)

    def test_social_redirect_distinto(self):
        r = self.c.post("/api/auth/social", json={"proveedor": "GOOGLE", "code": "x" * 20,
                                                  "redirect_uri": "http://malicioso.com"})
        self.assertEqual(r.status_code, 400)

    # ---------------- controles de los datos (como ADMIN) ----------------
    def test_post_invalido_400(self):
        r = self.c.post("/api/medicamentos", json={**BASE, "stock": -5, "nombre_comercial": "X1"},
                        headers=ADMIN)
        self.assertEqual(r.status_code, 400)
        cuerpo = r.get_json()
        self.assertEqual(cuerpo["motivo"], "validacion")
        self.assertIn("stock", cuerpo["errores"])
        self.assertIn("nombre_comercial", cuerpo["errores"])
        self.assertIn("X-Server", r.headers)

    def test_json_invalido(self):
        r = self.c.post("/api/medicamentos", data="no-json", content_type="text/plain", headers=ADMIN)
        self.assertEqual(r.status_code, 400)

    def test_put_sin_version(self):
        datos = {k: x for k, x in BASE.items() if k != "codigo"}
        r = self.c.put("/api/medicamentos/1", json=datos, headers=ADMIN)
        self.assertEqual(r.status_code, 400)
        self.assertIn("version", r.get_json()["errores"])

    def test_busqueda_con_simbolos(self):
        r = self.c.get("/api/medicamentos?q=%27%3B%20DROP%20TABLE", headers=ADMIN)
        self.assertEqual(r.status_code, 400)
        r = self.c.get("/api/catalogo?q=%27%3B%20DROP%20TABLE", headers=CLIENTE)
        self.assertEqual(r.status_code, 400)

    def test_delete_sin_version(self):
        self.assertEqual(self.c.delete("/api/medicamentos/1", headers=ADMIN).status_code, 400)

    def test_usuario_admin_invalido(self):
        r = self.c.post("/api/usuarios", json={"usuario": "Ana P", "password": "abc",
                                               "nombre_completo": "Ana", "rol": "JEFE"}, headers=ADMIN)
        self.assertEqual(r.status_code, 400)
        self.assertEqual(set(r.get_json()["errores"]), {"usuario", "password", "rol"})

    def test_ruta_inexistente_json(self):
        r = self.c.get("/api/nada")
        self.assertEqual(r.status_code, 404)
        self.assertEqual(r.get_json()["motivo"], "no_encontrado")


class TestErroresSQL(unittest.TestCase):
    """La API traduce los THROW de los procedimientos a códigos HTTP."""
    TEXTO = ("[42000] [Microsoft][ODBC Driver 17 for SQL Server][SQL Server]'Paracetamol Genfar' "
             "fue modificado por otro usuario. Recargue e intente de nuevo. (52001) (SQLExecDirectW)")

    def test_numero_y_mensaje(self):
        numero, texto = app_mod.numero_error(pyodbc.Error("42000", self.TEXTO))
        self.assertEqual(numero, 52001)
        self.assertEqual(app_mod.mensaje_sql(texto),
                         "'Paracetamol Genfar' fue modificado por otro usuario. Recargue e intente de nuevo.")

    def test_conflicto_adjunta_datos_actuales(self):
        def falla():
            raise pyodbc.Error("42000", self.TEXTO)
        with app.test_request_context():
            resp, status = app_mod.ejecutar_con_conflicto(falla, lambda: {"id": 1, "stock": 7, "version": 9})
        self.assertEqual(status, 409)
        cuerpo = resp.get_json()
        self.assertEqual(cuerpo["motivo"], "concurrencia")
        self.assertEqual(cuerpo["medicamento"]["stock"], 7)

    def test_stock_insuficiente_409(self):
        texto = self.TEXTO.replace("(52001)", "(52002)")
        with app.test_request_context():
            resp, status = app.handle_user_exception(pyodbc.Error("42000", texto))
        self.assertEqual(status, 409)
        self.assertEqual(resp.get_json()["motivo"], "stock")


if __name__ == "__main__":
    unittest.main()
