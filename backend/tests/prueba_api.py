"""
Prueba de INTEGRACIÓN contra la API real (necesita la BD con 03_datos.sql).

    python prueba_api.py --url http://127.0.0.1:5000 --url http://IP_API2:5001
    python prueba_api.py                       # IP virtual (ips.env)  · usa admin / Admin123

Crea el medicamento de prueba MED-0999 (al final queda INACTIVO; para
borrarlo:  DELETE FROM dbo.medicamentos WHERE codigo = 'MED-0999').
"""
import argparse
import os
import threading

import requests


def url_por_defecto():
    """http://IP_VIRTUAL:PUERTO_NGINX leído de ips.env (el único archivo de IPs)."""
    ips = {}
    ruta = os.path.join(os.path.dirname(__file__), "..", "..", "ips.env")
    for linea in open(ruta, encoding="utf-8"):
        if "=" in linea and not linea.lstrip().startswith("#"):
            k, val = linea.strip().split("=", 1)
            ips[k] = val
    return f"http://{ips['IP_VIRTUAL']}:{ips['PUERTO_NGINX']}"


def iniciar_sesion(url, usuario, clave):
    """POST /api/auth/login y deja el token en todas las peticiones (Unidad 3)."""
    s = requests.Session()
    r = s.post(f"{url}/api/auth/login", json={"usuario": usuario, "password": clave}, timeout=10)
    if not r.ok:
        raise SystemExit(f"No se pudo iniciar sesión como {usuario}: {r.text}")
    s.headers["Authorization"] = f"Bearer {r.json()['token']}"
    return s

p = argparse.ArgumentParser()
p.add_argument("--usuario", default="admin")
p.add_argument("--clave", default="Admin123")
p.add_argument("--url", action="append")
a = p.parse_args()
URLS = a.url or [url_por_defecto()]
S = iniciar_sesion(URLS[0], a.usuario, a.clave)
fallos = 0


def api(i=0):
    return f"{URLS[i % len(URLS)]}/api/medicamentos"


def check(nombre, condicion, detalle=""):
    global fallos
    if not condicion:
        fallos += 1
    print(f"{'✅' if condicion else '❌'} {nombre}" + (f"  -> {detalle}" if detalle else ""))


BASE = {
    "codigo": "MED-0999", "nombre_comercial": "Producto Integracion",
    "principio_activo": "Paracetamol", "laboratorio": "Genfar", "concentracion": "500 mg",
    "forma_farmaceutica": "TABLETA", "registro_sanitario": "9999-INT-01", "lote": "LINT01",
    "fecha_fabricacion": "2026-01-01", "fecha_vencimiento": "2029-01-01",
    "stock": 5, "precio_compra": 1.0, "precio_venta": 2.0,
}

# ---------------- LISTAR / BUSCAR ----------------
r = S.get(api(), params={"q": "losartan"})  # sin tilde, minúsculas
check("Búsqueda sin tildes encuentra 'Losartán'", r.ok and r.json()["total"] == 1, r.json().get("total"))
r = S.get(f"{api()}/alertas")
check("Alertas incluye MED-0019 (stock bajo)", any(m["codigo"] == "MED-0019" for m in r.json()["datos"]))

# ---------------- CREAR + CONTROLES ----------------
r = S.post(api(), json=BASE)
if r.status_code == 409:  # quedó de una corrida anterior
    print("   (MED-0999 ya existía, se reutiliza)")
    nuevo = S.get(api(), params={"q": "MED-0999"}).json()["datos"][0]
else:
    check("POST válido -> 201", r.status_code == 201, r.text[:120])
    nuevo = r.json()["medicamento"]

casos = {
    "Nombre duplicado (mayúsc/tildes/espacios)": ({"nombre_comercial": "  PARACETÁMOL   genfar "}, 409),
    "Stock negativo": ({"stock": -5}, 400),
    "Stock con texto": ({"stock": "diez"}, 400),
    "Stock decimal": ({"stock": 2.5}, 400),
    "Nombre con números": ({"nombre_comercial": "Paracetamol 500"}, 400),
    "Precio con letras": ({"precio_venta": "12abc"}, 400),
    "Venta < compra": ({"precio_compra": 5, "precio_venta": 1}, 400),
    "Código inválido": ({"codigo": "ABC"}, 400),
    "Código duplicado": ({"codigo": "MED-0001", "nombre_comercial": "Otro Nombre",
                          "registro_sanitario": "9999-INT-02"}, 409),
    "Vencido": ({"fecha_vencimiento": "2020-01-01"}, 400),
}
for nombre, (cambio, esperado) in casos.items():
    r = S.post(api(), json={**BASE, "codigo": "MED-0998", "registro_sanitario": "9999-INT-03",
                                   "nombre_comercial": "Producto Rechazado", **cambio})
    check(f"Rechaza: {nombre} -> {esperado}", r.status_code == esperado,
          f"{r.status_code} {r.json().get('errores') or r.json().get('error')}")

# ---------------- ACTUALIZAR + CONCURRENCIA OPTIMISTA ----------------
m = S.get(f"{api()}/{nuevo['id']}").json()["medicamento"]
cuerpo = {k: m[k] for k in m if k not in ("id", "codigo", "creado_en", "actualizado_en", "stock_bajo", "por_vencer")}
r = S.put(f"{api()}/{m['id']}", json={**cuerpo, "precio_venta": 2.5})
check("PUT con versión correcta -> 200", r.ok, r.text[:120])
check("La versión cambió tras el PUT", r.ok and r.json()["medicamento"]["version"] != m["version"])
r2 = S.put(f"{api(1)}/{m['id']}", json={**cuerpo, "precio_venta": 3.0})  # versión vieja
check("PUT con versión VIEJA (otro usuario) -> 409", r2.status_code == 409 and r2.json()["motivo"] == "concurrencia",
      r2.json().get("error"))

# Dos usuarios guardan A LA VEZ con la misma versión (uno por cada servidor)
m = S.get(f"{api()}/{nuevo['id']}").json()["medicamento"]
cuerpo = {k: m[k] for k in m if k not in ("id", "codigo", "creado_en", "actualizado_en", "stock_bajo", "por_vencer")}
barrera, res = threading.Barrier(2), []


def guardar(i, precio):
    barrera.wait()
    res.append(requests.put(f"{api(i)}/{m['id']}", json={**cuerpo, "precio_venta": precio},
                            headers={"Authorization": S.headers["Authorization"]}))


hs = [threading.Thread(target=guardar, args=(i, 4.0 + i)) for i in range(2)]
[h.start() for h in hs]
[h.join() for h in hs]
codigos = sorted(x.status_code for x in res)
check("Edición simultánea: 1 guarda y 1 recibe 409", codigos == [200, 409],
      f"{codigos} servidores={[x.headers.get('X-Server') for x in res]}")

# ---------------- STOCK ----------------
r = S.patch(f"{api()}/{nuevo['id']}/stock", json={"operacion": "SALIDA", "cantidad": 999})
check("Despachar más que el stock -> 409", r.status_code == 409, r.json().get("error"))
r = S.patch(f"{api()}/{nuevo['id']}/stock", json={"operacion": "SALIDA", "cantidad": -1})
check("Cantidad negativa -> 400", r.status_code == 400)

# ---------------- ELIMINAR (lógico) ----------------
m = S.get(f"{api()}/{nuevo['id']}").json()["medicamento"]
r = S.delete(f"{api()}/{m['id']}", params={"version": m["version"]})
if m["stock"] > 0:
    check("Eliminar con stock -> 409", r.status_code == 409, r.json().get("error"))
    S.patch(f"{api()}/{m['id']}/stock", json={"operacion": "SALIDA", "cantidad": m["stock"]})
    m = S.get(f"{api()}/{nuevo['id']}").json()["medicamento"]
    r = S.delete(f"{api()}/{m['id']}", params={"version": m["version"]})
check("Eliminar con stock 0 -> INACTIVO", r.ok and r.json()["medicamento"]["estado"] == "INACTIVO", r.text[:120])

print(f"\n{'TODO CORRECTO' if fallos == 0 else f'{fallos} FALLO(S)'}")
