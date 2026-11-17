"""
Prueba de CONCURRENCIA real.

    pip install requests
    python prueba_concurrencia.py                                   # IP virtual (Nginx)
    python prueba_concurrencia.py --url http://127.0.0.1:5000 --url http://127.0.0.1:5001

Con varias --url reparte los hilos entre ellas (simula el balanceador).
Lanza N despachos SIMULTÁNEOS del mismo medicamento (por defecto MED-0020,
que tiene 10 unidades). Con 20 hilos: deben pasar 10 y fallar 10 con 409,
y el stock debe quedar en 0, NUNCA negativo.
"""
import argparse
import threading
from collections import Counter

import requests

p = argparse.ArgumentParser()
p.add_argument("--url", action="append", help="Se puede repetir")
p.add_argument("--codigo", default="MED-0020")
p.add_argument("--hilos", type=int, default=20)
p.add_argument("--cantidad", type=int, default=1)
p.add_argument("--demora", type=int, default=200, help="ms que se retiene el bloqueo")
a = p.parse_args()
urls = a.url or ["http://10.79.7.200"]

api0 = f"{urls[0]}/api/medicamentos"
med = requests.get(api0, params={"q": a.codigo}, timeout=10).json()["datos"][0]
print(f"{med['codigo']} {med['nombre_comercial']}: stock inicial {med['stock']}")

barrera = threading.Barrier(a.hilos)   # todos salen exactamente a la vez
resultados = []
lock = threading.Lock()


def despachar(i):
    api = f"{urls[i % len(urls)]}/api/medicamentos"
    barrera.wait()
    r = requests.patch(f"{api}/{med['id']}/stock", params={"demora": a.demora},
                       json={"operacion": "SALIDA", "cantidad": a.cantidad}, timeout=60)
    cuerpo = r.json()
    msg = cuerpo.get("error") or f"stock {cuerpo['stock_anterior']} -> {cuerpo['medicamento']['stock']}"
    with lock:
        resultados.append((i, r.status_code, r.headers.get("X-Server", "?"), msg))


hilos = [threading.Thread(target=despachar, args=(i,)) for i in range(a.hilos)]
for h in hilos:
    h.start()
for h in hilos:
    h.join()

for i, st, srv, msg in sorted(resultados):
    print(f"#{i:02d}  HTTP {st}  {srv:<11} {msg}")

final = requests.get(f"{api0}/{med['id']}", timeout=10).json()["medicamento"]["stock"]
ok = sum(1 for r in resultados if r[1] == 200)
esperado = med["stock"] - ok * a.cantidad
print("\nPor servidor:", dict(Counter(r[2] for r in resultados)))
print(f"Exitosos: {ok}  |  409: {sum(1 for r in resultados if r[1] == 409)}")
print(f"Stock final: {final}  (esperado {esperado})  ->",
      "CORRECTO" if final == esperado and final >= 0 else "INCONSISTENTE")
