# Farmacia – Grupo 3

CRUD de medicamentos con **login por roles** (ADMIN / FARMACEUTICO / CLIENTE, token
de 5 minutos, Google y Facebook), **controles en 3 capas** (Flutter → Flask → SQL
Server), **vistas y procedimientos almacenados**, **concurrencia** (`UPDLOCK` +
`ROWVERSION`), **balanceo con NGINX** y **alta disponibilidad con Keepalived**
(1 master + 2 esclavos, IP virtual).

Base de datos: **`AppDistribuidas_2026_DB`**.

```
├── ips.env          ← ÚNICO archivo con IPs y puertos
├── aplicar_ips.py   ← regenera nginx, keepalived y la app a partir de ips.env
├── plantillas/      plantillas que usa aplicar_ips.py (no tienen IPs)
├── database/        01_schema · 02_vistas_procedimientos · 03_datos · 04_pruebas_controles · 05_login_api
├── backend/         app.py · auth.py · validators.py · db.py · config.py · respuestas.py · tests/
├── nginx/           nginx.conf · docker-compose.yml          (generados)
├── keepalived/      keepalived-server1/2/3 · check_nginx.sh  (generados) · instalar_nodo.sh
└── farmacia_app/    Flutter (lib/config_red.dart generado)
```

---

## 1. Cambiar de red: un solo archivo

Todas las IPs y puertos están en **`ips.env`**. Si cambian de red:

```powershell
notepad ips.env                 # cambiar las IPs
python aplicar_ips.py           # regenera nginx.conf, keepalived/*.conf, check_nginx.sh y config_red.dart
git add -A ; git commit -m "Cambio de IPs" ; git push
```

Luego en cada VM: `git pull` y `bash keepalived/instalar_nodo.sh <1|2|3>`, y volver a
ejecutar la app Flutter. La API lee `ips.env` directamente (en su `.env` se escribe
`${IP_BD}`, nunca una IP). `aplicar_ips.py` también imprime los comandos de firewall
con las IPs actuales.

| Variable | Valor actual | Qué es |
|---|---|---|
| `IP_SERVER1/2/3` | 10.79.20.38 · 10.79.16.19 · 10.79.20.2 | MASTER · ESCLAVO 1 · ESCLAVO 2 |
| `IP_VIRTUAL` / `PUERTO_NGINX` | 10.79.20.200 / 90 | la única dirección que usa la app |
| `IP_API1` / `PUERTO_API1` | 10.79.20.22 / 5000 | entorno 1 de la API (cliente) |
| `IP_API2` / `PUERTO_API2` | 10.79.20.38 / 5001 | entorno 2 de la API (Windows del Server 1) |
| `IP_BD` / `PUERTO_BD` | 10.79.20.22 / 1440 | SQL Server del cliente (instancia SITIO_AD_A) |

---

## 2. Topología

```
 App Flutter ──► http://IP_VIRTUAL:90        ← Keepalived mueve esta IP
                        │
     ┌──────────────────┼──────────────────┐
  Server1 MASTER    Server2 ESCLAVO1    Server3 ESCLAVO2      (VM Ubuntu: NGINX + Keepalived)
  prioridad 120     prioridad 110       prioridad 100
     └──────────────────┼──────────────────┘
              ┌─────────┴─────────┐
      API entorno 1          API entorno 2
      IP_API1:5000           IP_API2:5001
              └─────────┬─────────┘
                        ▼
      SQL Server SITIO_AD_A (IP_BD:1440): solo vistas y procedimientos
```

**Failover:** cae el MASTER → toma el ESCLAVO 1; cae también → toma el ESCLAVO 2.
Cuando el MASTER vuelve **recupera el control** aunque solo quede un esclavo
(preempt). Si NGINX falla en un nodo, `chk_nginx` le resta 50 (120→70, 110→60,
100→50): un nodo sano (≥100) siempre gana a uno caído.
**Si caen los tres**, la app muestra **"Sistema en mantenimiento"** y vuelve sola.

---

## 3. Roles y login (Unidad 3)

| Acción | ADMIN | FARMACEUTICO | CLIENTE |
|---|:-:|:-:|:-:|
| Catálogo completo (solo ACTIVOS) y detalle del producto | ✔ | ✔ | ✔ |
| Ver inventario completo, alertas, historial de stock | ✔ | ✔ | |
| Despachar / ingresar stock | ✔ | ✔ | |
| Crear, editar y dar de baja medicamentos | ✔ | | |
| Gestionar usuarios y roles, pruebas de concurrencia | ✔ | | |

Usuarios de prueba (`03_datos.sql`): **admin / Admin123**, **farmaceutico / Farma123**,
**cliente / Cliente123**.

- `POST /api/auth/login` devuelve un token de **5 minutos** (`TOKEN_MINUTOS` en `.env`).
  Cada petición envía `Authorization: Bearer <token>`; la API lo valida en la BD
  (`sp_auth_validar_token`). Token vencido o falso → **401** → la app vuelve al login
  con *"Sesión expirada"*. Rol sin permiso → **403**.
- En la BD se guarda el **SHA2_256 del token** y las contraseñas como **SHA2_512 + sal**.
- 5 contraseñas incorrectas seguidas → cuenta **bloqueada 5 minutos**.
- **Registro** desde el login: siempre crea un **CLIENTE** (lo decide la BD).
- **Google / Facebook** (opcional): ver sección 9.

---

## 4. Comandos de cada computadora

### Cliente (Windows, `IP_API1` / `IP_BD`) — BD + API :5000 + App

Requisito: SQL Server, instancia **SITIO_AD_A** con TCP/IP habilitado en el **puerto 1440**
(`PUERTO_BD` en `ips.env`) y `sqlcmd`.

```powershell
# 0) Una sola vez, PowerShell como ADMINISTRADOR (los comandos exactos los imprime: python aplicar_ips.py)
New-NetFirewallRule -DisplayName "API Farmacia 5000" -Direction Inbound -Protocol TCP -LocalPort 5000 -RemoteAddress 10.79.16.0/21 -Action Allow
New-NetFirewallRule -DisplayName "SQL Farmacia" -Direction Inbound -Protocol TCP -LocalPort 1440 -RemoteAddress 10.79.20.22,10.79.20.38 -Action Allow

# 1) Base de datos (01 crea la BD; volver a ejecutarlo BORRA los datos)
cd database
sqlcmd -S "localhost\SITIO_AD_A" -E -I -f 65001 -i 01_schema.sql
sqlcmd -S "localhost\SITIO_AD_A" -E -I -f 65001 -i 02_vistas_procedimientos.sql
sqlcmd -S "localhost\SITIO_AD_A" -E -I -f 65001 -i 03_datos.sql
sqlcmd -S "localhost\SITIO_AD_A" -E -I -f 65001 -i 05_login_api.sql
Restart-Service 'MSSQL$SITIO_AD_A'          # (administrador) aplica la autenticación mixta

# 2) API - entorno 1
cd ..\backend
pip install -r requirements.txt
copy .env.example .env                       # ya trae DB_SERVER=localhost,${PUERTO_BD}
python app.py --port 5000 --nombre cliente-5000

# 3) App Flutter (otra consola)
cd ..\farmacia_app
flutter pub get
flutter run -d windows
```

### Server 1 (Windows, `IP_API2`) — API :5001 (entorno 2)

```powershell
New-NetFirewallRule -DisplayName "API Farmacia 5001" -Direction Inbound -Protocol TCP -LocalPort 5001 -RemoteAddress 10.79.16.0/21 -Action Allow
git clone https://github.com/javierpea/leccion-distribuidas-farmacia.git
cd leccion-distribuidas-farmacia\backend
pip install -r requirements.txt
copy .env.example .env
#   En .env: comentar  DB_SERVER=localhost,${PUERTO_BD}  y descomentar las 3 líneas del entorno 2
#   (DB_SERVER=${IP_BD},${PUERTO_BD} · DB_UID · DB_PWD)
python app.py --port 5001 --nombre server1-5001
```

### Server 1, 2 y 3 — VM Ubuntu (VirtualBox, adaptador puente) — NGINX + Keepalived

```bash
git clone https://github.com/javierpea/leccion-distribuidas-farmacia.git
cd leccion-distribuidas-farmacia
bash keepalived/instalar_nodo.sh 1      # Server 1 (MASTER).  Server 2: ... 2   ·  Server 3: ... 3
```

`instalar_nodo.sh` instala Docker y Keepalived (la primera vez), levanta NGINX en el
puerto 90, copia `check_nginx.sh` y la configuración del nodo, reinicia Keepalived y
muestra si el nodo tiene la IP virtual. Después de un `git pull` se vuelve a ejecutar.

---

## 5. Apagar y encender NGINX / Keepalived (pruebas de failover)

Todos se ejecutan **dentro de la VM** del servidor que se quiere probar.

| Acción | Comando |
|---|---|
| Apagar NGINX | `sudo docker stop balanceador_nginx` |
| Encender NGINX | `sudo docker start balanceador_nginx` |
| Apagar Keepalived | `sudo systemctl stop keepalived` |
| Encender Keepalived | `sudo systemctl start keepalived` |
| Simular que se cae el servidor completo | `sudo docker stop balanceador_nginx && sudo systemctl stop keepalived` |
| Volver a levantar el servidor completo | `sudo docker start balanceador_nginx && sudo systemctl start keepalived` |
| ¿Este nodo tiene la IP virtual? | `ip -4 addr \| grep 10.79.20.200` |
| Ver MASTER/BACKUP en vivo | `sudo journalctl -u keepalived -f` |
| Estado | `sudo systemctl status keepalived` · `sudo docker ps` |

**Guion de prueba** (desde el cliente: `curl.exe -i http://10.79.20.200:90/api/health`
varias veces; `X-Balanceador` dice qué VM atendió y `X-Server` qué API):

1. Todo encendido → la IP virtual está en el **Server 1**.
2. Server 1: `sudo docker stop balanceador_nginx` → pasa al **Server 2** (prioridad 120−50=70 < 110).
3. Server 2: `sudo systemctl stop keepalived` → pasa al **Server 3**.
4. Server 1: `sudo docker start balanceador_nginx` → **vuelve al Server 1** (preempt),
   aunque el Server 2 siga apagado.
5. **Mantenimiento:** apagar NGINX en los 3 (o Keepalived en los 3, o las dos APIs) →
   la app muestra *"Sistema en mantenimiento"*. Al encender cualquiera vuelve sola.

Mientras la IP cambia de servidor (≈3 s) la app reintenta las consultas automáticamente,
así que el cliente no nota el cambio.

---

## 6. Base de datos: vistas y procedimientos

La API **no toca las tablas**: solo usa estas vistas y procedimientos, y el usuario SQL
`farmacia_app` solo tiene `SELECT` en las vistas y `EXECUTE` en los procedimientos.

| Vistas | Uso |
|---|---|
| `vw_catalogo` | CLIENTE: solo ACTIVOS, sin precio de compra, lote, registro ni stock exacto |
| `vw_medicamentos` · `vw_medicamentos_alertas` | personal: todo + `stock_bajo` / `por_vencer` |
| `vw_usuarios` | usuarios sin hash ni sal |
| `vw_movimientos_stock` | quién despachó / ingresó, cuándo y por qué API |

| Procedimientos | Endpoint |
|---|---|
| `sp_auth_login`, `sp_auth_login_social`, `sp_auth_validar_token`, `sp_auth_logout` | `/api/auth/*` |
| `sp_usuario_registrar`, `sp_usuario_crear`, `sp_usuario_actualizar` | registro y `/api/usuarios` |
| `sp_medicamento_insertar`, `sp_medicamento_actualizar`, `sp_medicamento_mover_stock`, `sp_medicamento_baja` | `/api/medicamentos` |

`04_pruebas_controles.sql` intenta 28 operaciones inválidas (medicamentos, usuarios,
tokens, procedimientos) y muestra que la BD **rechaza todas**.

### Endpoints

| Método | Ruta | Rol |
|---|---|---|
| GET | `/api/health` | público (NGINX y mantenimiento) |
| GET | `/api/auth/config` | público (qué botones de login mostrar) |
| POST | `/api/auth/login` · `/api/auth/registro` · `/api/auth/social` | público |
| POST | `/api/auth/logout` · GET `/api/auth/yo` | con sesión |
| GET | `/api/catalogo?q=` · `/api/catalogo/<id>` | todos |
| GET | `/api/medicamentos` · `/alertas` · `/<id>` · `/<id>/movimientos` | ADMIN, FARMACEUTICO |
| PATCH | `/api/medicamentos/<id>/stock` `{"operacion":"SALIDA","cantidad":3}` | ADMIN, FARMACEUTICO |
| POST / PUT / DELETE | `/api/medicamentos[/<id>]` (PUT y DELETE exigen `version`) | ADMIN |
| GET / POST / PUT | `/api/usuarios[/<id>]` (PUT exige `version`) | ADMIN |

Pruebas: `python -m unittest discover -s tests -v` (sin BD, 29 pruebas);
`python tests/prueba_api.py` y `python tests/prueba_concurrencia.py` (contra la IP virtual,
inician sesión solos).

---

## 7. Controles (defensa en profundidad)

| Regla | Flutter (teclado + validación) | Flask | SQL Server |
|---|---|---|---|
| Campos numéricos enteros | solo dígitos (no letras ni signos) | `entero()` | `INT` + `CHECK` |
| Precios con decimales | coma o punto → **siempre punto**, uno solo, máx. 2 decimales | `decimal_positivo()` | `DECIMAL(10,2)` + `CHECK > 0` |
| Nombre, principio, laboratorio, nombre completo | solo letras y espacios | regex | `CHECK NOT LIKE '%[^A-Za-zÁÉ…ñ ]%'` |
| Usuario | minúsculas, números, `.` y `_` | regex | `chk_usuario_formato` + `UNIQUE` |
| Correo | sin espacios, minúsculas | regex | `chk_usuario_email` + índice único |
| Contraseña | sin espacios, 8‑50, letras y números | ✔ | `fn_password_valida` + hash |
| Nombre de medicamento no repetido | – | consulta previa → 409 | `UNIQUE` + collation `CI_AI` |
| Stock nunca negativo | ✔ | ✔ | `CHECK` + `WHERE stock + Δ >= 0` en el SP |
| Rol permitido | menú según rol | `@requiere_rol` → 403 | `chk_usuario_rol` |
| Siempre un ADMIN activo | no deja quitarse el rol | – | SP + trigger |
| Campos extra / inyección SQL | – | lista blanca + parámetros `?` | solo SP |

**Demo "si falla uno, funciona el otro":** con `DESACTIVAR_VALIDACION_BACKEND=1` en el
`.env` de una API, la prueba **3. Controles del servidor** de la app muestra mensajes
con **`[BD]`**: los rechazó SQL Server.

## 8. Concurrencia

| Caso | Mecanismo | Resultado |
|---|---|---|
| 2 usuarios editan el mismo medicamento o usuario | `UPDLOCK` + `ROWVERSION` en el SP | uno guarda; el otro recibe **409** y la app ofrece cargar los datos actuales |
| N despachos simultáneos (por 5000 y 5001) | `UPDLOCK` serializa + `WHERE stock + Δ >= 0` | el stock **nunca** queda negativo; los sobrantes: **409 "Ya no hay stock"** |
| 2 registros con el mismo usuario a la vez | `UPDLOCK, HOLDLOCK` + `UNIQUE` | uno se crea; el otro **409** |
| Intentos de login simultáneos | `UPDLOCK` en `sp_auth_login` | el contador de intentos fallidos no se pierde |

---

## 9. Login con Google y Facebook (opcional)

Si las claves están vacías, la app oculta esos botones.

1. **Google:** [console.cloud.google.com](https://console.cloud.google.com) → APIs y servicios →
   Credenciales → *Crear ID de cliente OAuth* → tipo **App de escritorio**.
   Copiar el ID y el secreto en `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` del `.env`.
2. **Facebook:** [developers.facebook.com](https://developers.facebook.com) → Crear app →
   *Inicio de sesión con Facebook* → URI de redireccionamiento válido:
   **`http://localhost:8765/callback`**. Copiar ID y clave secreta en `FACEBOOK_APP_ID` /
   `FACEBOOK_APP_SECRET`.
3. Poner las **mismas** claves en el `.env` de las **dos** APIs y reiniciarlas.

La app abre el navegador, el usuario acepta, y el navegador vuelve a
`http://localhost:8765/callback`. La app envía ese código a la API, que (con el secreto)
lo verifica con Google/Facebook y crea la cuenta como **CLIENTE** si no existe.
Funciona en Windows y Android (no en Flutter Web). Mientras la app de Facebook esté en
"modo desarrollo", solo pueden entrar las cuentas agregadas como probadores.
