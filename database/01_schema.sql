/* =====================================================================
   FARMACIA - GRUPO 3 - TABLA: dbo.medicamentos
   Motor: SQL Server (LocalDB / Express / Developer)
   Base:  AppDistribuidas_2026_DB

   Defensa en profundidad: TODOS los controles que valida el backend
   (Flask) también están aquí. Si uno falla, el otro lo detiene.

   Ejecutar (SSMS: abrir y F5)  o:
     sqlcmd -S "(localdb)\MSSQLLocalDB" -E -f 65001 -i 01_schema.sql
   ===================================================================== */
USE AppDistribuidas_2026_DB;
GO

IF OBJECT_ID('dbo.medicamentos', 'U') IS NOT NULL
    DROP TABLE dbo.medicamentos;
GO

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
    -- (igual que la columna Versions de facturación)
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

/* ---------------------------------------------------------------------
   TRIGGERS: reglas que un CHECK no puede hacer (comparar con la fecha
   de hoy, comparar valor viejo vs nuevo). THROW cancela la operación.
   --------------------------------------------------------------------- */
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

/* ---------------------------------------------------------------------
   OPCIONAL (servidor SQL Server real del Server 3, NO en LocalDB):
   usuario propio para la API, solo con permisos sobre esta tabla.

   CREATE LOGIN farmacia_app WITH PASSWORD = 'Farmacia2026*', CHECK_POLICY = OFF;
   CREATE USER  farmacia_app FOR LOGIN farmacia_app;
   GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.medicamentos TO farmacia_app;
   --------------------------------------------------------------------- */
PRINT 'Tabla dbo.medicamentos creada con sus controles.';
GO
