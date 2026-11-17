# Farmacia – Grupo 3 – Tabla `dbo.medicamentos`

CRUD con **controles en 3 capas** (Flutter → Flask → SQL Server), **concurrencia**
(`UPDLOCK` + `ROWVERSION`, igual que en facturación), **balanceo con Nginx** y
**alta disponibilidad con Keepalived** (1 master + 2 esclavos, IP virtual).

Base de datos: **`AppDistribuidas_2026_DB`** (la de la materia).

```
farmacia_medicamentos/
├── database/   01_schema.sql · 02_datos.sql · 03_pruebas_controles.sql
├── backend/    app.py · validators.py · db.py · config.py · tests/
├── nginx/      nginx.conf · docker-compose.yml
├── keepalived/ keepalived-server1-master.conf · -server2-backup1 · -server3-backup2 · check_nginx.sh
└── farmacia_app/   (Flutter)
```

## Topología

| Equipo | IP | Rol | Qué corre |
|---|---|---|---|
| Cliente | 10.79.7.180 | Cliente · **Entorno API 1** | **BD** (SQL Server Express) · **API :5000** · **App Flutter** |
| Server 1 | 10.79.5.86 | **MASTER** (prioridad 120) · **Entorno API 2** | Windows: **API :5001** · VM Ubuntu: NGINX + Keepalived |
| Server 2 | 10.79.4.177 | **ESCLAVO 1** (prioridad 110) | VM Ubuntu: NGINX + Keepalived |
| Server 3 | 10.79.7.16 | **ESCLAVO 2** (prioridad 100) | VM Ubuntu: NGINX + Keepalived |

```
 App Flutter (cliente) ──► http://10.79.7.200:90   ← IP virtual (Keepalived)
                                   │
        ┌──────────────────────────┼──────────────────────────┐
   Server1 MASTER            Server2 ESCLAVO1           Server3 ESCLAVO2
   NGINX + Keepalived        NGINX + Keepalived         NGINX + Keepalived
        └──────────────────────────┼──────────────────────────┘
                  ┌────────────────┴────────────────┐
                  ▼                                 ▼
       Entorno 1: Cliente                 Entorno 2: Server 1 (Windows)
       10.79.7.180:5000                   10.79.5.86:5001
                  └────────────────┬────────────────┘
                                   ▼
             BD del cliente: SQL Server Express, 10.79.7.180,1433
```

La API del puerto 5001 corre en Windows del Server 1, **independiente** de su VM
(NGINX + Keepalived): si se cae el NGINX del Server 1, la API 5001 sigue atendiendo
a través del NGINX que tome la IP virtual.

**Failover:** si cae el MASTER, la IP pasa al ESCLAVO 1; si también cae, pasa al
ESCLAVO 2. Cuando el MASTER vuelve, **recupera la IP** (preempt), aunque solo quede
un esclavo activo. Si NGINX falla en un nodo, `chk_nginx` le resta 50 a la prioridad
(120→70, 110→60, 100→50): un nodo con NGINX sano (≥100) siempre gana a uno caído.
**Si caen los tres**, la app muestra **"Sistema en mantenimiento"** y vuelve sola.

> ⚠ **Antes de desplegar:**
> - Verifiquen que **10.79.7.200 está libre** (`ping 10.79.7.200` no debe responder).
>   Si está ocupada, cámbienla en los 3 `keepalived-*.conf` y en `farmacia_app/lib/config.dart`.
> - Revisen la máscara (`/22`) y la interfaz de la VM (`enp0s3`) con `ip a`.

---

## Guía rápida: comandos de cada computadora

### Cliente (Windows, 10.79.7.180) — BD + API :5000 + App

**LocalDB no acepta conexiones de otra PC**, y la API 5001 (Server 1) usa esta BD:
instalen **SQL Server Express** (+ `sqlcmd`) y en *SQL Server Configuration Manager →
Protocolos de SQLEXPRESS → TCP/IP*: **Habilitado**; en *Direcciones IP → IPAll*: puertos
dinámicos vacío y **Puerto TCP 1433**.

```powershell
# 0) Una sola vez, PowerShell como ADMINISTRADOR
New-NetFirewallRule -DisplayName "API Farmacia 5000" -Direction Inbound -Protocol TCP -LocalPort 5000 -RemoteAddress 10.79.4.0/22 -Action Allow
New-NetFirewallRule -DisplayName "SQL Farmacia"      -Direction Inbound -Protocol TCP -LocalPort 1433 -RemoteAddress 10.79.5.86 -Action Allow

# 1) Base de datos
cd database
sqlcmd -S "localhost\SQLEXPRESS" -E -Q "IF DB_ID('AppDistribuidas_2026_DB') IS NULL CREATE DATABASE AppDistribuidas_2026_DB"
sqlcmd -S "localhost\SQLEXPRESS" -E -f 65001 -i 01_schema.sql
sqlcmd -S "localhost\SQLEXPRESS" -E -f 65001 -i 02_datos.sql
sqlcmd -S "localhost\SQLEXPRESS" -E -f 65001 -i 04_login_api.sql
Restart-Service 'MSSQL$SQLEXPRESS'            # (como administrador) aplica el TCP 1433 y la autenticación mixta

# 2) API - Entorno 1 (puerto 5000)
cd ..\backend
pip install -r requirements.txt
copy .env.example .env                         # ya trae DB_SERVER=localhost\SQLEXPRESS
python app.py --host 0.0.0.0 --port 5000 --nombre cliente-5000      # dejar abierta

# 3) App Flutter (apunta a http://10.79.7.200:90)
cd ..\farmacia_app
flutter pub get
flutter run -d windows
```

### Server 1 (Windows, 10.79.5.86) — API :5001 (Entorno 2)

Requiere Python y el **ODBC Driver 17 for SQL Server**.

```powershell
# Una sola vez, PowerShell como ADMINISTRADOR
New-NetFirewallRule -DisplayName "API Farmacia 5001" -Direction Inbound -Protocol TCP -LocalPort 5001 -RemoteAddress 10.79.4.0/22 -Action Allow

git clone https://github.com/javierpea/leccion-distribuidas-farmacia.git
cd leccion-distribuidas-farmacia\backend
pip install -r requirements.txt
copy .env.example .env
# En .env: comentar  DB_SERVER=localhost\SQLEXPRESS  y descomentar las 3 líneas del Entorno 2:
#   DB_SERVER=10.79.7.180,1433 · DB_UID=farmacia_app · DB_PWD=Farmacia2026*
python app.py --host 0.0.0.0 --port 5001 --nombre server1-5001      # dejar abierta
```

### Server 1, 2 y 3 (VM Ubuntu en VirtualBox) — NGINX + Keepalived

Keepalived no existe para Windows: en cada server se usa una **VM Ubuntu** con la red
en **Adaptador puente** y **Modo promiscuo: Permitir todo** (mejor por cable).
Dentro de la VM:

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 keepalived curl git
git clone https://github.com/javierpea/leccion-distribuidas-farmacia.git
cd leccion-distribuidas-farmacia

# NGINX (puerto 90)
cd nginx && sudo docker compose up -d && cd ..

# Keepalived
sudo cp keepalived/check_nginx.sh /etc/keepalived/ && sudo chmod +x /etc/keepalived/check_nginx.sh
sudo cp keepalived/keepalived-server1-master.conf  /etc/keepalived/keepalived.conf   # SOLO Server 1
sudo cp keepalived/keepalived-server2-backup1.conf /etc/keepalived/keepalived.conf   # SOLO Server 2
sudo cp keepalived/keepalived-server3-backup2.conf /etc/keepalived/keepalived.conf   # SOLO Server 3
sudo systemctl enable keepalived && sudo systemctl restart keepalived
```

> Si la IP virtual aparece en **dos** VMs a la vez, la red bloquea multicast:
> descomenten el bloque `unicast_*` de los `keepalived-*.conf` con las IPs de las VMs.

### Pruebas

```bash
# En cada VM
curl http://127.0.0.1:90/health                 # OK
curl -i http://127.0.0.1:90/api/health          # X-Server alterna cliente-5000 / server1-5001
ip a | grep 10.79.7.200                         # solo la VM con la IP virtual la muestra
sudo journalctl -u keepalived -f                # ver MASTER/BACKUP en vivo

# En el cliente
curl.exe -i http://10.79.7.200:90/api/health
```

**Failover:**
1. `sudo docker stop balanceador_nginx` en la VM del Server 1 → la IP pasa al Server 2.
2. Lo mismo en la VM del Server 2 → pasa al Server 3.
3. `sudo docker start balanceador_nginx` en el Server 1 → **vuelve al MASTER**.
4. Detener los 3 → la app muestra **mantenimiento**; al levantar uno, vuelve sola.

---

## Detalle de la API

Pruebas (en el cliente):
```bash
cd backend
python -m unittest discover -s tests -p "test_*.py" -v                            # sin BD (17)
python tests/prueba_api.py --url http://127.0.0.1:5000 --url http://10.79.5.86:5001    # CRUD + controles (21)
python tests/prueba_concurrencia.py --url http://127.0.0.1:5000 --url http://10.79.5.86:5001
```

### Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/health` | Estado (lo usan Nginx y Flutter) |
| GET | `/api/medicamentos?q=&estado=&requiere_receta=` | Listar / buscar (sin importar tildes) |
| GET | `/api/medicamentos/alertas` | Stock bajo o vence en ≤ 60 días |
| GET | `/api/medicamentos/<id>` | Obtener uno |
| POST | `/api/medicamentos` | Crear |
| PUT | `/api/medicamentos/<id>` | Actualizar (**exige `version`**) |
| PATCH | `/api/medicamentos/<id>/stock` | `{"operacion":"SALIDA","cantidad":3}` |
| DELETE | `/api/medicamentos/<id>?version=N` | Baja lógica (solo con stock 0) |

Cada respuesta trae la cabecera **`X-Server`** (`cliente-5000` / `server1-5001`) y, al pasar
por NGINX, **`X-Upstream`** con la IP:puerto que respondió.
`03_pruebas_controles.sql` intenta 14 operaciones inválidas y muestra que la BD las rechaza.

## 4. App Flutter (cliente 10.79.7.180)

```bash
cd farmacia_app
flutter pub get
flutter run           # Android / Windows / Chrome
```

La URL está en `lib/config.dart` (`http://10.79.7.200:90`). Con el ícono ⚙ se puede
apuntar a un Flask directo (por ejemplo `http://127.0.0.1:5000` para probar en tu PC).

---

## Controles (defensa en profundidad)

| Regla | Flutter (teclado + validación) | Flask | SQL Server |
|---|---|---|---|
| Nombre **no repetido** (ignora mayúsculas y tildes) | – | consulta previa → 409 | `UNIQUE` + collation `CI_AI` |
| Stock **nunca negativo**, solo enteros | solo dígitos | `entero()` → 400 | `CHECK (stock >= 0)` + `WHERE stock + Δ >= 0` |
| Precio solo números, > 0, máx. 2 decimales | formatter decimal | `decimal_positivo()` | `DECIMAL(10,2)` + `CHECK > 0` |
| Precio venta ≥ compra | ✔ | ✔ | `chk_precio_venta_mayor` |
| Nombre / principio / laboratorio **solo letras** | filtro de letras | regex | `CHECK NOT LIKE '%[^A-Za-zÁÉ…ñ ]%'` |
| Código `MED-0001`, lote y registro **letras + números** | mayúsculas A‑Z 0‑9 - | regex | `CHECK LIKE` (collation `BIN2`) |
| Concentración `500 mg`, `250 mg/5 ml` | filtro | regex exacta | `CHECK LIKE` |
| Fechas: venc. > fab., fab. no futura, no vencido al crear | ✔ | ✔ | `CHECK` + trigger |
| Forma / estado de una lista | Dropdown | ✔ | `CHECK IN (...)` |
| Código no modificable, RETIRADO no editable | campo bloqueado | ✔ | trigger (`THROW`) |
| Borrar solo con stock 0 (baja lógica) | ✔ | ✔ | trigger `AFTER DELETE` |
| Campos extra / inyección SQL | – | lista blanca + parámetros `?` | – |

**Demo "si falla uno, funciona el otro":** en el `.env` de un Flask pongan
`DESACTIVAR_VALIDACION_BACKEND=1` y reinicien. En la app, la prueba **3. Controles del
servidor** muestra mensajes con **`[BD]`**: los rechazó SQL Server.

## Concurrencia

| Caso | Mecanismo | Resultado |
|---|---|---|
| 2 usuarios editan el mismo registro | `WITH (UPDLOCK, ROWLOCK)` + `ROWVERSION` | 1 guarda; el otro recibe **409**, y la app muestra los datos actuales para recargar |
| N usuarios despachan a la vez (por 5000 y 5001) | `UPDLOCK` serializa + `UPDATE … WHERE stock + Δ >= 0` | el stock **nunca** queda negativo; los sobrantes reciben **409 "Ya no hay stock"** |
| Dos crean el mismo nombre a la vez | consulta previa + `UNIQUE` | uno se crea; el otro recibe **409 duplicado** |

Resultado real en LocalDB (20 despachos simultáneos sobre `MED-0020`, stock 10,
repartidos 10 y 10 entre flask-5000 y flask-5001): **10 exitosos, 10 rechazados con 409,
stock final 0 → CORRECTO.**
