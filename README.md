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

| Equipo | IP | Rol | Servicios |
|---|---|---|---|
| Server 1 | 10.79.5.86 | **MASTER** (prioridad 120) | Windows: Flask :5000 y :5001 · VM Ubuntu: Nginx + Keepalived |
| Server 2 | 10.79.4.177 | **ESCLAVO 1** (prioridad 110) | Windows: Flask :5000 y :5001 · VM Ubuntu: Nginx + Keepalived |
| Server 3 | 10.79.7.16 | **ESCLAVO 2** (prioridad 100) | Windows: Flask :5000 y :5001 · SQL Server · VM Ubuntu: Nginx + Keepalived |
| Cliente | 10.79.7.180 | Cliente | App Flutter → **http://10.79.7.200:90** (IP virtual) |

```
                Flutter (10.79.7.180)
                        │
                        ▼
              IP VIRTUAL 10.79.7.200   ← Keepalived la mueve
      ┌─────────────────┼─────────────────┐
  Server1 (MASTER)  Server2 (ESCLAVO1)  Server3 (ESCLAVO2)
   Nginx              Nginx              Nginx
      └─ upstream (6 APIs): .86 / .177 / .16  ×  :5000 y :5001 ─┘
                        │
       SQL Server 10.79.7.16 · AppDistribuidas_2026_DB
```

**Failover:** si cae el MASTER, la IP pasa al ESCLAVO 1; si también cae, pasa al
ESCLAVO 2. Cuando el MASTER vuelve, **recupera la IP** (preempt), aunque solo quede
un esclavo activo. Si NGINX falla en un nodo, `chk_nginx` le resta 50 a la prioridad
(120→70, 110→60, 100→50): un nodo con NGINX sano (≥100) siempre gana a uno caído.
**Si caen los tres**, la app Flutter muestra **"Sistema en mantenimiento"**,
reintenta cada 5 s y vuelve sola cuando un servidor responde.

> ⚠ **Antes de desplegar:**
> - Verifiquen que **10.79.7.200 está libre** (`ping 10.79.7.200` no debe responder).
>   Si está ocupada, cambien la IP virtual en los 3 `keepalived-*.conf` y en `farmacia_app/lib/config.dart`.
> - Revisen la máscara (puse `/22`) y el nombre de la interfaz de la VM (puse `enp0s3`) con `ip a`.
> - Si el rol de cada compañero es otro, solo intercambien los archivos de keepalived.

---

## 1. Base de datos (SQL Server)

### En tu PC (desarrollo) – ya está creada
La tabla `dbo.medicamentos` ya existe en `(localdb)\MSSQLLocalDB` → `AppDistribuidas_2026_DB`
con los 20 medicamentos de prueba. Para recrearla:

```bash
cd database
sqlcmd -S "(localdb)\MSSQLLocalDB" -E -f 65001 -i 01_schema.sql
sqlcmd -S "(localdb)\MSSQLLocalDB" -E -f 65001 -i 02_datos.sql
sqlcmd -S "(localdb)\MSSQLLocalDB" -E -f 65001 -i 03_pruebas_controles.sql
```

En SSMS también sirve: abrir cada archivo y presionar **F5**. `03_pruebas_controles.sql`
intenta 14 operaciones inválidas y muestra que la BD **rechaza todas**.

### En el Server 3 (despliegue)
> **LocalDB NO acepta conexiones de otras PC.** Para que los Flask de Server 1 y 2 se
> conecten, el Server 3 necesita **SQL Server Express o Developer** (Windows o Linux).

1. Instalar SQL Server, activar **autenticación mixta** y **TCP/IP en el puerto 1433**
   (SQL Server Configuration Manager → Protocols → TCP/IP → Enabled; reiniciar el servicio).
2. Crear la base `AppDistribuidas_2026_DB` y ejecutar `01_schema.sql` y `02_datos.sql`.
3. Crear el usuario de la API (está comentado al final de `01_schema.sql`):
   ```sql
   CREATE LOGIN farmacia_app WITH PASSWORD = 'Farmacia2026*', CHECK_POLICY = OFF;
   USE AppDistribuidas_2026_DB;
   CREATE USER farmacia_app FOR LOGIN farmacia_app;
   GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.medicamentos TO farmacia_app;
   ```
4. Abrir el firewall solo para los Flask:
   `New-NetFirewallRule -DisplayName "SQL Farmacia" -Direction Inbound -Protocol TCP -LocalPort 1433 -RemoteAddress 10.79.5.86,10.79.4.177,10.79.7.16 -Action Allow`

## 2. API Flask (los 3 servidores, puertos 5000 y 5001)

Necesitan el **ODBC Driver 17 o 18 for SQL Server** (en Linux: paquete `msodbcsql18`).

```bash
cd backend
python -m venv venv
venv\Scripts\activate            # Linux: source venv/bin/activate
pip install -r requirements.txt
copy .env.example .env           # descomentar DB_SERVER=10.79.7.16,1433 + DB_UID/DB_PWD

# En CADA servidor, dos consolas (dos instancias de la misma API):
python app.py --port 5000 --nombre pc1-5000     # PC2: pc2-5000 · PC3: pc3-5000
python app.py --port 5001 --nombre pc1-5001     # PC2: pc2-5001 · PC3: pc3-5001
```

Pruebas:
```bash
python -m unittest discover -s tests -p "test_*.py" -v                            # sin BD (17)
python tests/prueba_api.py --url http://127.0.0.1:5000 --url http://127.0.0.1:5001    # CRUD + controles (21)
python tests/prueba_concurrencia.py --url http://127.0.0.1:5000 --url http://127.0.0.1:5001
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

Cada respuesta trae la cabecera **`X-Server`** (p. ej. `pc2-5001`) y, al pasar por NGINX,
**`X-Upstream`** con la IP:puerto que respondió.

## 3. Nginx + Keepalived (los 3 PCs Windows)

**Keepalived no existe para Windows** (y en Docker Desktop / WSL2 la IP virtual
queda dentro de una red NAT y la LAN no la ve). Por eso, igual que en la Unidad 2
(`enp0s3` es la interfaz de VirtualBox), en **cada PC Windows** se crea una
**VM Ubuntu en VirtualBox** que corre NGINX (Docker) + Keepalived:

```
 PC Windows (10.79.x.x)                    VM Ubuntu (adaptador PUENTE)
 ├─ Flask :5000 y :5001 (+ SQL en PC3)     ├─ Docker: balanceador_nginx  90 -> 8080
 └─ VirtualBox ─────────────────────────►  └─ Keepalived  (IP virtual 10.79.7.200)
```

**3.1 VirtualBox (en cada PC):** Configuración → Red → Adaptador 1 →
**Conectado a: Adaptador puente** (la tarjeta con la que salen a la red 10.79.x),
**Modo promiscuo: Permitir todo**. Mejor por cable: con Wi‑Fi el modo puente puede
no dejar pasar la IP virtual.

**3.2 Windows (los 3 PCs):** las APIs deben escuchar en `0.0.0.0` y el firewall
debe dejar entrar a las VMs (PowerShell como administrador):

```powershell
python app.py --host 0.0.0.0 --port 5000 --nombre pc1-5000
python app.py --host 0.0.0.0 --port 5001 --nombre pc1-5001
New-NetFirewallRule -DisplayName "Flask Farmacia" -Direction Inbound -Protocol TCP -LocalPort 5000,5001 -RemoteAddress 10.79.4.0/22 -Action Allow
```

**3.3 VM Ubuntu (en los 3 PCs):**

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 keepalived curl
# copiar las carpetas nginx/ y keepalived/ del repo a la VM
cd nginx && sudo docker compose up -d          # NGINX en el puerto 90
curl http://127.0.0.1:90/health                # -> OK
curl http://127.0.0.1:90/api/health            # repetir: X-Server va rotando pc1/pc2/pc3 · 5000/5001

sudo cp ../keepalived/check_nginx.sh /etc/keepalived/ && sudo chmod +x /etc/keepalived/check_nginx.sh
# UNO de estos según el PC:
sudo cp ../keepalived/keepalived-server1-master.conf  /etc/keepalived/keepalived.conf   # PC 10.79.5.86
sudo cp ../keepalived/keepalived-server2-backup1.conf /etc/keepalived/keepalived.conf   # PC 10.79.4.177
sudo cp ../keepalived/keepalived-server3-backup2.conf /etc/keepalived/keepalived.conf   # PC 10.79.7.16
sudo systemctl enable keepalived && sudo systemctl restart keepalived
ip a | grep 10.79.7.200       # solo la VM que tiene la IP virtual la muestra
```

> Si la IP virtual aparece en **dos** VMs a la vez, la red bloquea multicast:
> descomenten el bloque `unicast_*` de los 3 `keepalived-*.conf` con las IPs
> puente de las VMs (`ip a` en cada una).
> Si editan los archivos en Windows, guárdenlos con fin de línea **LF**
> (con CRLF `check_nginx.sh` falla siempre). El `.gitattributes` ya lo fuerza.

**Prueba de failover** (desde Windows: `curl http://10.79.7.200:90/api/health`;
en las VMs: `sudo journalctl -u keepalived -f`):
1. `sudo docker stop balanceador_nginx` en la VM del PC1 → la IP pasa al ESCLAVO 1.
2. Lo mismo en la VM del PC2 → pasa al ESCLAVO 2.
3. `sudo docker start balanceador_nginx` en la VM del PC1 → **vuelve al MASTER**.
4. Detener los 3 → Flutter muestra **mantenimiento**; al levantar uno, la app vuelve sola.

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
