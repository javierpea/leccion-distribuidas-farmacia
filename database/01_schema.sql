/* =====================================================================
   FARMACIA - GRUPO 3 - ESQUEMA COMPLETO
   Motor: SQL Server (instancia SITIO_AD_A, puerto 1440)   Base: AppDistribuidas_2026_DB

   Tablas:
     dbo.medicamentos       catálogo (con ROWVERSION para concurrencia)
     dbo.usuarios           login con roles ADMIN / FARMACEUTICO / CLIENTE
     dbo.tokens             tokens de sesión (Unidad 3: token temporal)
     dbo.movimientos_stock  quién despachó / ingresó stock y cuándo

   Defensa en profundidad: TODOS los controles que valida la app Flutter
   y el backend (Flask) también están aquí. Si uno falla, el otro lo detiene.

   ORDEN DE EJECUCIÓN (en el equipo de la BD):
     sqlcmd -S "localhost\SITIO_AD_A" -E -I -f 65001 -i 01_schema.sql
     sqlcmd -S "localhost\SITIO_AD_A" -E -I -f 65001 -i 02_vistas_procedimientos.sql
     sqlcmd -S "localhost\SITIO_AD_A" -E -I -f 65001 -i 03_datos.sql
   ¡OJO! Volver a ejecutar este archivo BORRA todos los datos.
   ===================================================================== */
SET QUOTED_IDENTIFIER ON;   -- necesario para los índices filtrados (email único)
SET ANSI_NULLS ON;
GO
IF DB_ID('AppDistribuidas_2026_DB') IS NULL
    CREATE DATABASE AppDistribuidas_2026_DB;
GO
USE AppDistribuidas_2026_DB;
GO

-- Borrar en orden (primero las tablas que tienen llaves foráneas)
IF OBJECT_ID('dbo.tokens', 'U')            IS NOT NULL DROP TABLE dbo.tokens;
IF OBJECT_ID('dbo.movimientos_stock', 'U') IS NOT NULL DROP TABLE dbo.movimientos_stock;
IF OBJECT_ID('dbo.usuarios', 'U')          IS NOT NULL DROP TABLE dbo.usuarios;
IF OBJECT_ID('dbo.medicamentos', 'U')      IS NOT NULL DROP TABLE dbo.medicamentos;
GO

/* =====================================================================
   1) MEDICAMENTOS
   ===================================================================== */
CREATE TABLE dbo.medicamentos (
    id                  INT IDENTITY(1,1) NOT NULL,

    -- Código: letras y números con formato fijo  MED-0001
    codigo              VARCHAR(12)  NOT NULL,

    -- Solo letras (con tildes/ñ) y espacios.
    -- Collation CI_AI: "Paracetamol" = "PARACETÁMOL" para el UNIQUE.
    nombre_comercial    NVARCHAR(100) COLLATE Latin1_General_100_CI_AI NOT NULL,
    principio_activo    NVARCHAR(100) COLLATE Latin1_General_100_CI_AI NOT NULL,
    laboratorio         NVARCHAR(80)  COLLATE Latin1_General_100_CI_AI NOT NULL,

    -- Número + unidad:  500 mg | 250 mg/5 ml | 1 g | 1 %
    concentracion       VARCHAR(30)  NOT NULL,
    forma_farmaceutica  VARCHAR(20)  NOT NULL,

    -- Letras MAYÚSCULAS, números y guion
    registro_sanitario  VARCHAR(20)  NOT NULL,
    lote                VARCHAR(20)  NOT NULL,

    fecha_fabricacion   DATE NOT NULL,
    fecha_vencimiento   DATE NOT NULL,

    -- Solo números enteros, nunca negativos
    stock               INT NOT NULL CONSTRAINT df_med_stock DEFAULT (0),
    stock_minimo        INT NOT NULL CONSTRAINT df_med_stock_min DEFAULT (10),

    -- Solo números con 2 decimales, mayores a 0
    precio_compra       DECIMAL(10,2) NOT NULL,
    precio_venta        DECIMAL(10,2) NOT NULL,

    requiere_receta     BIT NOT NULL CONSTRAINT df_med_receta DEFAULT (0),
    estado              VARCHAR(10) NOT NULL CONSTRAINT df_med_estado DEFAULT ('ACTIVO'),

    -- Concurrencia optimista: SQL Server la cambia SOLO en cada UPDATE
    version             ROWVERSION NOT NULL,
    creado_en           DATETIME2(0) NOT NULL CONSTRAINT df_med_creado DEFAULT (SYSDATETIME()),
    actualizado_en      DATETIME2(0) NOT NULL CONSTRAINT df_med_actualizado DEFAULT (SYSDATETIME()),

    CONSTRAINT pk_medicamentos PRIMARY KEY (id),

    -- =================== CONTROLES UNIQUE ===================
    CONSTRAINT uq_medicamentos_nombre   UNIQUE (nombre_comercial),   -- sin importar mayúsc./tildes
    CONSTRAINT uq_medicamentos_codigo   UNIQUE (codigo),
    CONSTRAINT uq_medicamentos_registro UNIQUE (registro_sanitario),

    -- =================== CONTROLES CHECK ====================
    -- (COLLATE ..._BIN2 = comparación exacta: A-Z son solo mayúsculas ASCII)
    CONSTRAINT chk_codigo_formato CHECK (
        codigo COLLATE Latin1_General_100_BIN2 LIKE 'MED-[0-9][0-9][0-9][0-9]'
        AND DATALENGTH(codigo) = 8),

    CONSTRAINT chk_nombre_solo_letras CHECK (
        nombre_comercial COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[^A-Za-zÁÉÍÓÚÜÑáéíóúüñ ]%'
        AND nombre_comercial NOT LIKE N'%  %'
        AND DATALENGTH(nombre_comercial) = DATALENGTH(LTRIM(RTRIM(nombre_comercial)))
        AND LEN(nombre_comercial) BETWEEN 3 AND 100),

    CONSTRAINT chk_principio_solo_letras CHECK (
        principio_activo COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[^A-Za-zÁÉÍÓÚÜÑáéíóúüñ ]%'
        AND principio_activo NOT LIKE N'%  %'
        AND DATALENGTH(principio_activo) = DATALENGTH(LTRIM(RTRIM(principio_activo)))
        AND LEN(principio_activo) BETWEEN 3 AND 100),

    CONSTRAINT chk_laboratorio_solo_letras CHECK (
        laboratorio COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[^A-Za-zÁÉÍÓÚÜÑáéíóúüñ ]%'
        AND laboratorio NOT LIKE N'%  %'
        AND DATALENGTH(laboratorio) = DATALENGTH(LTRIM(RTRIM(laboratorio)))
        AND LEN(laboratorio) BETWEEN 2 AND 80),

    -- Empieza con número, solo caracteres válidos y termina en una unidad
    CONSTRAINT chk_concentracion_formato CHECK (
        concentracion COLLATE Latin1_General_100_BIN2 LIKE '[0-9]%'
        AND concentracion COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-zA-Z ./%]%'
        AND (   concentracion COLLATE Latin1_General_100_BIN2 LIKE '%g'
             OR concentracion COLLATE Latin1_General_100_BIN2 LIKE '%ml'
             OR concentracion COLLATE Latin1_General_100_BIN2 LIKE '%UI'
             OR concentracion COLLATE Latin1_General_100_BIN2 LIKE '%[%]')),

    CONSTRAINT chk_forma_valida CHECK (forma_farmaceutica IN
        ('TABLETA','CAPSULA','JARABE','SUSPENSION','INYECTABLE','CREMA','GOTAS','POLVO')),

    CONSTRAINT chk_registro_formato CHECK (
        registro_sanitario COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^A-Z0-9-]%'
        AND registro_sanitario NOT LIKE '-%' AND registro_sanitario NOT LIKE '%-'
        AND registro_sanitario NOT LIKE '%--%'
        AND LEN(registro_sanitario) BETWEEN 2 AND 20),

    CONSTRAINT chk_lote_formato CHECK (
        lote COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^A-Z0-9-]%'
        AND lote NOT LIKE '-%' AND lote NOT LIKE '%-' AND lote NOT LIKE '%--%'
        AND LEN(lote) BETWEEN 3 AND 20),

    CONSTRAINT chk_fechas_orden      CHECK (fecha_vencimiento > fecha_fabricacion),
    CONSTRAINT chk_stock_no_negativo CHECK (stock >= 0 AND stock <= 100000),
    CONSTRAINT chk_stock_minimo      CHECK (stock_minimo >= 0 AND stock_minimo <= 10000),
    CONSTRAINT chk_precio_compra     CHECK (precio_compra > 0 AND precio_compra <= 99999.99),
    CONSTRAINT chk_precio_venta      CHECK (precio_venta > 0 AND precio_venta <= 99999.99),
    CONSTRAINT chk_precio_venta_mayor CHECK (precio_venta >= precio_compra),
    CONSTRAINT chk_estado_valido     CHECK (estado IN ('ACTIVO','INACTIVO','VENCIDO','RETIRADO'))
);
GO
CREATE INDEX ix_medicamentos_estado ON dbo.medicamentos (estado);
GO

/* =====================================================================
   2) USUARIOS  (Unidad 3 - Práctica Final: tabla Usuarios con Rol)
      - La contraseña NUNCA se guarda en texto plano: se guarda
        SHA2_512(sal + contraseña) con una sal aleatoria por usuario.
      - Las cuentas de Google/Facebook no tienen contraseña: se
        identifican por proveedor + proveedor_id.
   ===================================================================== */
CREATE TABLE dbo.usuarios (
    id                 INT IDENTITY(1,1) NOT NULL,
    -- Nombre de usuario para iniciar sesión: minúsculas, números, punto y _
    usuario            VARCHAR(30)   COLLATE Latin1_General_100_CI_AI NOT NULL,
    password_hash      VARBINARY(64) NULL,
    password_salt      VARBINARY(16) NULL,
    -- Solo letras y espacios
    nombre_completo    NVARCHAR(100) COLLATE Latin1_General_100_CI_AI NOT NULL,
    email              VARCHAR(100)  COLLATE Latin1_General_100_CI_AI NULL,
    rol                VARCHAR(15)   NOT NULL CONSTRAINT df_usu_rol DEFAULT ('CLIENTE'),
    proveedor          VARCHAR(10)   NOT NULL CONSTRAINT df_usu_proveedor DEFAULT ('LOCAL'),
    proveedor_id       VARCHAR(100)  NULL,
    estado             BIT           NOT NULL CONSTRAINT df_usu_estado DEFAULT (1),
    -- Control de fuerza bruta: 5 intentos fallidos = bloqueado 5 minutos
    intentos_fallidos  TINYINT       NOT NULL CONSTRAINT df_usu_intentos DEFAULT (0),
    bloqueado_hasta    DATETIME2(0)  NULL,
    ultimo_acceso      DATETIME2(0)  NULL,
    -- Concurrencia optimista (dos admins editando el mismo usuario)
    version            ROWVERSION    NOT NULL,
    creado_en          DATETIME2(0)  NOT NULL CONSTRAINT df_usu_creado DEFAULT (SYSDATETIME()),
    actualizado_en     DATETIME2(0)  NOT NULL CONSTRAINT df_usu_actualizado DEFAULT (SYSDATETIME()),

    CONSTRAINT pk_usuarios PRIMARY KEY (id),
    CONSTRAINT uq_usuarios_usuario UNIQUE (usuario),

    CONSTRAINT chk_usuario_formato CHECK (
        usuario COLLATE Latin1_General_100_BIN2 LIKE '[a-z]%'
        AND usuario COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^a-z0-9._]%'
        AND LEN(usuario) BETWEEN 4 AND 30),

    CONSTRAINT chk_usuario_nombre CHECK (
        nombre_completo COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[^A-Za-zÁÉÍÓÚÜÑáéíóúüñ ]%'
        AND nombre_completo NOT LIKE N'%  %'
        AND DATALENGTH(nombre_completo) = DATALENGTH(LTRIM(RTRIM(nombre_completo)))
        AND LEN(nombre_completo) BETWEEN 3 AND 100),

    CONSTRAINT chk_usuario_email CHECK (
        email IS NULL OR (
            email LIKE '_%@_%._%'
            AND email NOT LIKE '%@%@%'
            AND email NOT LIKE '%..%'
            AND email COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^a-z0-9@._+-]%'
            AND LEN(email) BETWEEN 6 AND 100)),

    CONSTRAINT chk_usuario_rol CHECK (rol IN ('ADMIN','FARMACEUTICO','CLIENTE')),
    CONSTRAINT chk_usuario_proveedor CHECK (proveedor IN ('LOCAL','GOOGLE','FACEBOOK')),

    -- LOCAL: tiene contraseña. GOOGLE/FACEBOOK: tiene proveedor_id y no contraseña.
    CONSTRAINT chk_usuario_credenciales CHECK (
        (proveedor = 'LOCAL' AND password_hash IS NOT NULL AND password_salt IS NOT NULL
             AND proveedor_id IS NULL)
     OR (proveedor <> 'LOCAL' AND proveedor_id IS NOT NULL
             AND password_hash IS NULL AND password_salt IS NULL)),

    CONSTRAINT chk_usuario_intentos CHECK (intentos_fallidos BETWEEN 0 AND 10)
);
GO
-- El email (si lo tiene) no se repite; la cuenta social tampoco
CREATE UNIQUE INDEX uq_usuarios_email ON dbo.usuarios (email) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX uq_usuarios_proveedor ON dbo.usuarios (proveedor, proveedor_id)
    WHERE proveedor_id IS NOT NULL;
GO

/* =====================================================================
   3) TOKENS  (Unidad 3: token temporal que valida la API en cada petición)
      Se guarda el SHA2_256 del token: si alguien lee esta tabla no
      puede usar los tokens. El token real solo lo tiene la app.
   ===================================================================== */
CREATE TABLE dbo.tokens (
    id                INT IDENTITY(1,1) NOT NULL,
    usuario_id        INT          NOT NULL,
    token_hash        BINARY(32)   NOT NULL,
    fecha_creacion    DATETIME2(0) NOT NULL CONSTRAINT df_tok_creacion DEFAULT (SYSDATETIME()),
    fecha_expiracion  DATETIME2(0) NOT NULL,
    activo            BIT          NOT NULL CONSTRAINT df_tok_activo DEFAULT (1),
    ip_origen         VARCHAR(45)  NULL,

    CONSTRAINT pk_tokens PRIMARY KEY (id),
    CONSTRAINT fk_tokens_usuario FOREIGN KEY (usuario_id) REFERENCES dbo.usuarios (id),
    CONSTRAINT uq_tokens_hash UNIQUE (token_hash),
    CONSTRAINT chk_tokens_fechas CHECK (fecha_expiracion > fecha_creacion)
);
GO
CREATE INDEX ix_tokens_usuario ON dbo.tokens (usuario_id, activo);
GO

/* =====================================================================
   4) MOVIMIENTOS DE STOCK  (trazabilidad: quién despachó qué)
   ===================================================================== */
CREATE TABLE dbo.movimientos_stock (
    id               INT IDENTITY(1,1) NOT NULL,
    medicamento_id   INT          NOT NULL,
    usuario_id       INT          NOT NULL,
    operacion        VARCHAR(7)   NOT NULL,
    cantidad         INT          NOT NULL,
    stock_anterior   INT          NOT NULL,
    stock_nuevo      INT          NOT NULL,
    servidor         VARCHAR(30)  NULL,          -- qué API lo atendió (5000 / 5001)
    fecha            DATETIME2(0) NOT NULL CONSTRAINT df_mov_fecha DEFAULT (SYSDATETIME()),

    CONSTRAINT pk_movimientos PRIMARY KEY (id),
    CONSTRAINT fk_mov_medicamento FOREIGN KEY (medicamento_id) REFERENCES dbo.medicamentos (id),
    CONSTRAINT fk_mov_usuario     FOREIGN KEY (usuario_id)     REFERENCES dbo.usuarios (id),
    CONSTRAINT chk_mov_operacion  CHECK (operacion IN ('ENTRADA','SALIDA')),
    CONSTRAINT chk_mov_cantidad   CHECK (cantidad BETWEEN 1 AND 10000),
    CONSTRAINT chk_mov_cuadre     CHECK (
        stock_nuevo >= 0
        AND stock_nuevo = stock_anterior + CASE WHEN operacion = 'ENTRADA' THEN cantidad ELSE -cantidad END)
);
GO
CREATE INDEX ix_mov_medicamento ON dbo.movimientos_stock (medicamento_id, fecha);
GO

/* =====================================================================
   TRIGGERS: reglas que un CHECK no puede hacer (comparar con la fecha
   de hoy, comparar valor viejo vs nuevo). THROW cancela la operación.
   ===================================================================== */
CREATE OR ALTER TRIGGER dbo.trg_medicamentos_insert
ON dbo.medicamentos AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted WHERE fecha_fabricacion > CAST(GETDATE() AS DATE))
        THROW 50001, 'La fecha de fabricación no puede ser futura', 1;
    IF EXISTS (SELECT 1 FROM inserted WHERE fecha_vencimiento <= CAST(GETDATE() AS DATE))
        THROW 50002, 'No se puede registrar un medicamento vencido', 1;
END;
GO

CREATE OR ALTER TRIGGER dbo.trg_medicamentos_update
ON dbo.medicamentos AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted i JOIN deleted d ON d.id = i.id WHERE i.codigo <> d.codigo)
        THROW 50003, 'El código de un medicamento no se puede modificar', 1;

    IF EXISTS (SELECT 1 FROM deleted WHERE estado = 'RETIRADO')
        THROW 50004, 'Un medicamento RETIRADO no se puede modificar', 1;

    IF EXISTS (SELECT 1 FROM inserted i JOIN deleted d ON d.id = i.id
               WHERE i.stock < d.stock AND i.estado <> 'ACTIVO')
        THROW 50005, 'Solo se puede despachar stock de medicamentos ACTIVOS', 1;

    IF EXISTS (SELECT 1 FROM inserted i JOIN deleted d ON d.id = i.id
               WHERE i.creado_en <> d.creado_en)
        THROW 50006, 'La fecha de creación no se puede modificar', 1;
END;
GO

-- La API hace borrado LÓGICO. Un DELETE físico solo se permite sin stock.
CREATE OR ALTER TRIGGER dbo.trg_medicamentos_delete
ON dbo.medicamentos AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted WHERE stock > 0)
        THROW 50007, 'No se puede eliminar un medicamento con stock', 1;
END;
GO

-- Usuarios: el nombre de usuario no cambia y SIEMPRE debe quedar un ADMIN activo
CREATE OR ALTER TRIGGER dbo.trg_usuarios_update_delete
ON dbo.usuarios AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted i JOIN deleted d ON d.id = i.id WHERE i.usuario <> d.usuario)
        THROW 50010, 'El nombre de usuario no se puede modificar', 1;

    IF EXISTS (SELECT 1 FROM deleted WHERE rol = 'ADMIN' AND estado = 1)
       AND NOT EXISTS (SELECT 1 FROM dbo.usuarios WHERE rol = 'ADMIN' AND estado = 1)
        THROW 50011, 'Debe quedar al menos un administrador activo', 1;
END;
GO

PRINT 'Esquema creado: medicamentos, usuarios, tokens, movimientos_stock.';
GO
