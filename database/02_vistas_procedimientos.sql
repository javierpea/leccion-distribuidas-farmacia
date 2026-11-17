/* =====================================================================
   FARMACIA - VISTAS, FUNCIONES Y PROCEDIMIENTOS ALMACENADOS
   (Unidad 1: vistas y SPs consumidos por la API · Unidad 2: concurrencia
    · Unidad 3: login con token y roles)

     sqlcmd -S "localhost\SITIO_AD_A" -E -I -f 65001 -i 02_vistas_procedimientos.sql

   La API Flask SOLO usa estas vistas y procedimientos (no toca las tablas
   directamente). El usuario SQL de la API (05_login_api.sql) solo tiene
   permiso de SELECT sobre las vistas y EXECUTE sobre los procedimientos.

   CONCURRENCIA en cada procedimiento que modifica datos:
     1. SELECT ... WITH (UPDLOCK, ROWLOCK): bloquea la fila. Si dos
        peticiones llegan a la vez (una por la API 5000 y otra por la 5001)
        la segunda ESPERA a que termine la primera y ve los datos nuevos.
     2. ROWVERSION: el cliente envía la versión que leyó; si cambió -> 52001.
     3. El UPDATE repite la condición en el WHERE (guardia final) y la
        tabla tiene sus CHECK.
     4. UPDLOCK + HOLDLOCK al buscar duplicados (registro de usuarios):
        dos registros simultáneos con el mismo nombre no pasan los dos.

   CÓDIGOS DE ERROR (THROW) que la API traduce a HTTP:
     52001 concurrencia (409)      52002 stock insuficiente (409)
     52003 estado no permite (409) 52004 medicamento no existe (404)
     52005 vencido (409)           52006 stock máximo (400)
     52007 código no modificable (400)
     53001 usuario repetido (409)  53002 correo repetido (409)
     53003 contraseña débil (400)  53004 usuario no existe (404)
     53005 no puede quitarse su rol (409)
     53006 cuenta social sin contraseña (400)
     53007 debe quedar un admin (409)
   ===================================================================== */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
USE AppDistribuidas_2026_DB;
GO

/* =====================================================================
   FUNCIONES
   ===================================================================== */
-- SHA2_512(sal + contraseña). La sal es distinta para cada usuario.
CREATE OR ALTER FUNCTION dbo.fn_hash_password (@salt VARBINARY(16), @password NVARCHAR(50))
RETURNS VARBINARY(64)
AS
BEGIN
    RETURN HASHBYTES('SHA2_512', @salt + CAST(@password AS VARBINARY(100)));
END;
GO

-- 8 a 50 caracteres, al menos una letra y un número, sin espacios
CREATE OR ALTER FUNCTION dbo.fn_password_valida (@password NVARCHAR(100))
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN @password IS NOT NULL
                 AND LEN(@password) BETWEEN 8 AND 50
                 AND CHARINDEX(N' ', @password) = 0
                 AND @password LIKE N'%[A-Za-z]%'
                 AND @password LIKE N'%[0-9]%'
                THEN 1 ELSE 0 END;
END;
GO

/* =====================================================================
   VISTAS
   ===================================================================== */
-- ADMIN y FARMACEUTICO: todos los campos + indicadores calculados
CREATE OR ALTER VIEW dbo.vw_medicamentos
AS
SELECT m.id, m.codigo, m.nombre_comercial, m.principio_activo, m.laboratorio,
       m.concentracion, m.forma_farmaceutica, m.registro_sanitario, m.lote,
       m.fecha_fabricacion, m.fecha_vencimiento, m.stock, m.stock_minimo,
       m.precio_compra, m.precio_venta, m.requiere_receta, m.estado,
       m.version, m.creado_en, m.actualizado_en,
       CAST(CASE WHEN m.stock <= m.stock_minimo THEN 1 ELSE 0 END AS BIT) AS stock_bajo,
       CAST(CASE WHEN m.fecha_vencimiento <= DATEADD(DAY, 60, CAST(GETDATE() AS DATE))
                 THEN 1 ELSE 0 END AS BIT) AS por_vencer
  FROM dbo.medicamentos m;
GO

-- CLIENTE: solo medicamentos ACTIVOS y no vencidos, SIN datos internos
-- (no expone precio de compra, lote, registro sanitario ni stock exacto)
CREATE OR ALTER VIEW dbo.vw_catalogo
AS
SELECT m.id, m.codigo, m.nombre_comercial, m.principio_activo, m.laboratorio,
       m.concentracion, m.forma_farmaceutica, m.fecha_vencimiento,
       m.precio_venta, m.requiere_receta,
       CAST(CASE WHEN m.stock > 0 THEN 1 ELSE 0 END AS BIT) AS disponible
  FROM dbo.medicamentos m
 WHERE m.estado = 'ACTIVO'
   AND m.fecha_vencimiento > CAST(GETDATE() AS DATE);
GO

-- Stock bajo o vence en 60 días o menos
CREATE OR ALTER VIEW dbo.vw_medicamentos_alertas
AS
SELECT *
  FROM dbo.vw_medicamentos
 WHERE estado = 'ACTIVO' AND (stock_bajo = 1 OR por_vencer = 1);
GO

-- Usuarios SIN la contraseña (ni hash ni sal)
CREATE OR ALTER VIEW dbo.vw_usuarios
AS
SELECT u.id, u.usuario, u.nombre_completo, u.email, u.rol, u.proveedor, u.estado,
       CAST(CASE WHEN u.bloqueado_hasta > SYSDATETIME() THEN 1 ELSE 0 END AS BIT) AS bloqueado,
       u.bloqueado_hasta, u.ultimo_acceso, u.version, u.creado_en, u.actualizado_en
  FROM dbo.usuarios u;
GO

-- Historial de stock con nombres
CREATE OR ALTER VIEW dbo.vw_movimientos_stock
AS
SELECT mv.id, mv.fecha, mv.operacion, mv.cantidad, mv.stock_anterior, mv.stock_nuevo,
       mv.servidor, m.id AS medicamento_id, m.codigo, m.nombre_comercial,
       u.usuario, u.rol
  FROM dbo.movimientos_stock mv
  JOIN dbo.medicamentos m ON m.id = mv.medicamento_id
  JOIN dbo.usuarios u     ON u.id = mv.usuario_id;
GO

/* =====================================================================
   AUTENTICACIÓN (Unidad 3)
   ===================================================================== */
-- Crea un token aleatorio de 64 caracteres (32 bytes en hexadecimal).
-- Guarda solo su SHA2_256 y devuelve el token real a la API.
CREATE OR ALTER PROCEDURE dbo.sp_auth_crear_token
    @usuario_id INT,
    @minutos    INT,
    @ip         VARCHAR(45),
    @token      CHAR(64)     OUTPUT,
    @expiracion DATETIME2(0) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @minutos IS NULL OR @minutos NOT BETWEEN 1 AND 1440 SET @minutos = 5;

    SET @token = CONVERT(CHAR(64), CRYPT_GEN_RANDOM(32), 2);
    SET @expiracion = DATEADD(MINUTE, @minutos, SYSDATETIME());

    -- Limpieza: los tokens vencidos de este usuario quedan inactivos
    UPDATE dbo.tokens SET activo = 0
     WHERE usuario_id = @usuario_id AND activo = 1 AND fecha_expiracion <= SYSDATETIME();

    INSERT INTO dbo.tokens (usuario_id, token_hash, fecha_expiracion, ip_origen)
    VALUES (@usuario_id, HASHBYTES('SHA2_256', @token), @expiracion, @ip);

    UPDATE dbo.usuarios
       SET intentos_fallidos = 0, bloqueado_hasta = NULL, ultimo_acceso = SYSDATETIME()
     WHERE id = @usuario_id;
END;
GO

-- POST /api/auth/login  (usuario o correo + contraseña)
-- Devuelve SIEMPRE una fila con "resultado":
--   OK | CREDENCIALES | BLOQUEADO | INACTIVO | SOCIAL
-- (no usa THROW para que el contador de intentos fallidos sí se guarde)
CREATE OR ALTER PROCEDURE dbo.sp_auth_login
    @usuario  VARCHAR(100),
    @password NVARCHAR(100),
    @minutos  INT = 5,
    @ip       VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tc INT = @@TRANCOUNT;
    IF @tc = 0 BEGIN TRAN;

    DECLARE @id INT, @hash VARBINARY(64), @salt VARBINARY(16), @estado BIT,
            @bloqueado DATETIME2(0), @intentos TINYINT, @proveedor VARCHAR(10);

    -- UPDLOCK: dos intentos simultáneos del mismo usuario se atienden en
    -- orden, así el contador de intentos fallidos no se pierde.
    SELECT @id = id, @hash = password_hash, @salt = password_salt, @estado = estado,
           @bloqueado = bloqueado_hasta, @intentos = intentos_fallidos, @proveedor = proveedor
      FROM dbo.usuarios WITH (UPDLOCK, ROWLOCK)
     WHERE usuario = @usuario OR email = @usuario;

    DECLARE @resultado VARCHAR(20) = 'OK',
            @mensaje   NVARCHAR(200) = N'Login correcto';

    IF @id IS NULL
        SELECT @resultado = 'CREDENCIALES', @mensaje = N'Usuario o contraseña incorrectos';
    ELSE IF @bloqueado IS NOT NULL AND @bloqueado > SYSDATETIME()
        SELECT @resultado = 'BLOQUEADO',
               @mensaje = CONCAT(N'Cuenta bloqueada por intentos fallidos. Intente después de las ',
                                 CONVERT(VARCHAR(8), @bloqueado, 108));
    ELSE IF @proveedor <> 'LOCAL'
        SELECT @resultado = 'SOCIAL',
               @mensaje = CONCAT(N'Esta cuenta ingresa con el botón de ',
                                 CASE @proveedor WHEN 'GOOGLE' THEN N'Google' ELSE N'Facebook' END);
    ELSE IF dbo.fn_password_valida(@password) = 0
         OR @hash <> dbo.fn_hash_password(@salt, @password)
    BEGIN
        SET @intentos = @intentos + 1;
        IF @intentos >= 5
        BEGIN
            UPDATE dbo.usuarios
               SET intentos_fallidos = 0, bloqueado_hasta = DATEADD(MINUTE, 5, SYSDATETIME())
             WHERE id = @id;
            SELECT @resultado = 'BLOQUEADO',
                   @mensaje = N'Demasiados intentos fallidos: la cuenta queda bloqueada 5 minutos';
        END
        ELSE
        BEGIN
            UPDATE dbo.usuarios SET intentos_fallidos = @intentos WHERE id = @id;
            SELECT @resultado = 'CREDENCIALES',
                   @mensaje = CONCAT(N'Usuario o contraseña incorrectos (', 5 - @intentos,
                                     N' intento(s) antes del bloqueo)');
        END
    END
    ELSE IF @estado = 0
        SELECT @resultado = 'INACTIVO', @mensaje = N'Usuario desactivado. Comuníquese con el administrador';

    DECLARE @token CHAR(64), @expiracion DATETIME2(0);
    IF @resultado = 'OK'
        EXEC dbo.sp_auth_crear_token @id, @minutos, @ip, @token OUTPUT, @expiracion OUTPUT;

    IF @tc = 0 COMMIT;

    SELECT @resultado AS resultado, @mensaje AS mensaje, @token AS token, @expiracion AS expiracion,
           u.id, u.usuario, u.nombre_completo, u.email, u.rol, u.proveedor
      FROM (SELECT 1 AS fila) f
      LEFT JOIN dbo.vw_usuarios u ON u.id = @id AND @resultado = 'OK';
END;
GO

-- POST /api/auth/social  (Google / Facebook)
-- La API ya verificó la identidad con el proveedor. Si la cuenta no
-- existe se crea como CLIENTE. Resultado: OK | INACTIVO | EMAIL_EXISTE
CREATE OR ALTER PROCEDURE dbo.sp_auth_login_social
    @proveedor        VARCHAR(10),
    @proveedor_id     VARCHAR(100),
    @email            VARCHAR(100) = NULL,
    @nombre_completo  NVARCHAR(100),
    @usuario_sugerido VARCHAR(30),
    @minutos          INT = 5,
    @ip               VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tc INT = @@TRANCOUNT;
    IF @tc = 0 BEGIN TRAN;

    DECLARE @id INT, @estado BIT, @nuevo BIT = 0,
            @resultado VARCHAR(20) = 'OK', @mensaje NVARCHAR(200) = N'Login correcto';

    SELECT @id = id, @estado = estado
      FROM dbo.usuarios WITH (UPDLOCK, HOLDLOCK)
     WHERE proveedor = @proveedor AND proveedor_id = @proveedor_id;

    IF @id IS NULL
    BEGIN
        IF @email IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.usuarios WITH (UPDLOCK, HOLDLOCK) WHERE email = @email)
            SELECT @resultado = 'EMAIL_EXISTE',
                   @mensaje = N'Ese correo ya tiene una cuenta. Ingrese con la forma que usó al registrarse';
        ELSE
        BEGIN
            -- Usuario único: juan.perez, juan.perez2, juan.perez3 ...
            DECLARE @candidato VARCHAR(30) = @usuario_sugerido, @n INT = 1;
            WHILE EXISTS (SELECT 1 FROM dbo.usuarios WITH (UPDLOCK, HOLDLOCK) WHERE usuario = @candidato)
            BEGIN
                SET @n += 1;
                SET @candidato = CONCAT(LEFT(@usuario_sugerido, 25), @n);
            END;

            INSERT INTO dbo.usuarios (usuario, nombre_completo, email, rol, proveedor, proveedor_id)
            VALUES (@candidato, @nombre_completo, @email, 'CLIENTE', @proveedor, @proveedor_id);
            SELECT @id = CAST(SCOPE_IDENTITY() AS INT), @estado = 1, @nuevo = 1;
        END
    END

    IF @resultado = 'OK' AND @estado = 0
        SELECT @resultado = 'INACTIVO', @mensaje = N'Usuario desactivado. Comuníquese con el administrador';

    DECLARE @token CHAR(64), @expiracion DATETIME2(0);
    IF @resultado = 'OK'
        EXEC dbo.sp_auth_crear_token @id, @minutos, @ip, @token OUTPUT, @expiracion OUTPUT;

    IF @tc = 0 COMMIT;

    SELECT @resultado AS resultado, @mensaje AS mensaje, @token AS token, @expiracion AS expiracion,
           @nuevo AS nuevo, u.id, u.usuario, u.nombre_completo, u.email, u.rol, u.proveedor
      FROM (SELECT 1 AS fila) f
      LEFT JOIN dbo.vw_usuarios u ON u.id = @id AND @resultado = 'OK';
END;
GO

-- Lo llama la API en CADA petición protegida (Authorization: Bearer ...)
-- Sin filas = token inválido, expirado, cerrado o usuario desactivado -> 401
CREATE OR ALTER PROCEDURE dbo.sp_auth_validar_token
    @token VARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.id, u.usuario, u.nombre_completo, u.email, u.rol, u.proveedor,
           t.fecha_expiracion AS expiracion
      FROM dbo.tokens t
      JOIN dbo.usuarios u ON u.id = t.usuario_id
     WHERE t.token_hash = HASHBYTES('SHA2_256', @token)
       AND t.activo = 1
       AND t.fecha_expiracion > SYSDATETIME()
       AND u.estado = 1;
END;
GO

-- POST /api/auth/logout
CREATE OR ALTER PROCEDURE dbo.sp_auth_logout
    @token VARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.tokens SET activo = 0
     WHERE token_hash = HASHBYTES('SHA2_256', @token) AND activo = 1;
    SELECT @@ROWCOUNT AS sesiones_cerradas;
END;
GO

/* =====================================================================
   USUARIOS
   ===================================================================== */
-- ADMIN crea usuarios con cualquier rol
CREATE OR ALTER PROCEDURE dbo.sp_usuario_crear
    @usuario         VARCHAR(50),
    @password        NVARCHAR(100),
    @nombre_completo NVARCHAR(200),
    @email           VARCHAR(200) = NULL,
    @rol             VARCHAR(15) = 'CLIENTE',
    @estado          BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF dbo.fn_password_valida(@password) = 0
        THROW 53003, N'La contraseña debe tener de 8 a 50 caracteres, con letras y números y sin espacios', 1;

    DECLARE @tc INT = @@TRANCOUNT;
    IF @tc = 0 BEGIN TRAN;

    -- UPDLOCK + HOLDLOCK bloquea también el "hueco": si dos personas se
    -- registran con el mismo usuario a la vez, la segunda espera y luego
    -- ve que ya existe (el UNIQUE de la tabla es la última defensa).
    IF EXISTS (SELECT 1 FROM dbo.usuarios WITH (UPDLOCK, HOLDLOCK) WHERE usuario = @usuario)
        THROW 53001, N'Ese nombre de usuario ya está registrado', 1;
    IF @email IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.usuarios WITH (UPDLOCK, HOLDLOCK) WHERE email = @email)
        THROW 53002, N'Ese correo ya está registrado', 1;

    DECLARE @salt VARBINARY(16) = CRYPT_GEN_RANDOM(16);
    INSERT INTO dbo.usuarios (usuario, password_hash, password_salt, nombre_completo,
                              email, rol, proveedor, estado)
    VALUES (@usuario, dbo.fn_hash_password(@salt, @password), @salt, @nombre_completo,
            @email, @rol, 'LOCAL', @estado);
    DECLARE @id INT = CAST(SCOPE_IDENTITY() AS INT);

    IF @tc = 0 COMMIT;
    SELECT * FROM dbo.vw_usuarios WHERE id = @id;
END;
GO

-- POST /api/auth/registro: el registro público SIEMPRE crea un CLIENTE
CREATE OR ALTER PROCEDURE dbo.sp_usuario_registrar
    @usuario         VARCHAR(50),
    @password        NVARCHAR(100),
    @nombre_completo NVARCHAR(200),
    @email           VARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.sp_usuario_crear @usuario = @usuario, @password = @password,
         @nombre_completo = @nombre_completo, @email = @email,
         @rol = 'CLIENTE', @estado = 1;
END;
GO

-- PUT /api/usuarios/{id}  (ADMIN). @password NULL = no se cambia.
CREATE OR ALTER PROCEDURE dbo.sp_usuario_actualizar
    @id              INT,
    @nombre_completo NVARCHAR(200),
    @email           VARCHAR(200) = NULL,
    @rol             VARCHAR(15),
    @estado          BIT,
    @version         BINARY(8),
    @password        NVARCHAR(100) = NULL,
    @desbloquear     BIT = 0,
    @admin_id        INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tc INT = @@TRANCOUNT;
    IF @tc = 0 BEGIN TRAN;

    DECLARE @ver BINARY(8), @rol_actual VARCHAR(15), @estado_actual BIT,
            @proveedor VARCHAR(10), @usuario VARCHAR(30), @msg NVARCHAR(300);

    -- 1) Bloqueo pesimista de la fila
    SELECT @ver = version, @rol_actual = rol, @estado_actual = estado,
           @proveedor = proveedor, @usuario = usuario
      FROM dbo.usuarios WITH (UPDLOCK, ROWLOCK)
     WHERE id = @id;

    IF @ver IS NULL
        THROW 53004, N'No existe el usuario', 1;

    -- 2) Concurrencia optimista
    IF @ver <> @version
    BEGIN
        SET @msg = CONCAT(N'El usuario ''', @usuario,
                          N''' fue modificado por otro administrador. Recargue e intente de nuevo.');
        THROW 52001, @msg, 1;
    END;

    IF @id = @admin_id AND (@rol <> 'ADMIN' OR @estado = 0)
        THROW 53005, N'No puede quitarse el rol de administrador ni desactivar su propia cuenta', 1;

    IF @rol_actual = 'ADMIN' AND @estado_actual = 1 AND (@rol <> 'ADMIN' OR @estado = 0)
       AND NOT EXISTS (SELECT 1 FROM dbo.usuarios WITH (UPDLOCK, HOLDLOCK)
                        WHERE rol = 'ADMIN' AND estado = 1 AND id <> @id)
        THROW 53007, N'Debe quedar al menos un administrador activo', 1;

    IF @email IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.usuarios WITH (UPDLOCK, HOLDLOCK) WHERE email = @email AND id <> @id)
        THROW 53002, N'Ese correo ya está registrado', 1;

    IF @password IS NOT NULL AND @proveedor <> 'LOCAL'
        THROW 53006, N'Las cuentas de Google o Facebook no usan contraseña', 1;

    IF @password IS NOT NULL AND dbo.fn_password_valida(@password) = 0
        THROW 53003, N'La contraseña debe tener de 8 a 50 caracteres, con letras y números y sin espacios', 1;

    DECLARE @salt VARBINARY(16) = CASE WHEN @password IS NOT NULL THEN CRYPT_GEN_RANDOM(16) END;

    -- 3) Guardia final en el WHERE (SQL Server cambia el ROWVERSION solo)
    UPDATE dbo.usuarios
       SET nombre_completo   = @nombre_completo,
           email             = @email,
           rol               = @rol,
           estado            = @estado,
           password_salt     = COALESCE(@salt, password_salt),
           password_hash     = CASE WHEN @salt IS NOT NULL
                                    THEN dbo.fn_hash_password(@salt, @password)
                                    ELSE password_hash END,
           intentos_fallidos = CASE WHEN @desbloquear = 1 THEN 0 ELSE intentos_fallidos END,
           bloqueado_hasta   = CASE WHEN @desbloquear = 1 THEN NULL ELSE bloqueado_hasta END,
           actualizado_en    = SYSDATETIME()
     WHERE id = @id AND version = @version;

    IF @@ROWCOUNT = 0
        THROW 52001, N'El usuario cambió mientras se guardaba. Recargue.', 1;

    -- Si cambió el rol, se desactivó o cambió la contraseña: se cierran sus sesiones
    IF @rol <> @rol_actual OR @estado = 0 OR @password IS NOT NULL
        UPDATE dbo.tokens SET activo = 0 WHERE usuario_id = @id AND activo = 1;

    IF @tc = 0 COMMIT;
    SELECT * FROM dbo.vw_usuarios WHERE id = @id;
END;
GO

/* =====================================================================
   MEDICAMENTOS
   (Los parámetros de texto son más largos que la columna a propósito:
    si llega un texto muy largo, SQL Server da error de truncamiento en
    vez de recortarlo en silencio.)
   ===================================================================== */
-- POST /api/medicamentos  (ADMIN)
CREATE OR ALTER PROCEDURE dbo.sp_medicamento_insertar
    @codigo             VARCHAR(50),
    @nombre_comercial   NVARCHAR(200),
    @principio_activo   NVARCHAR(200),
    @laboratorio        NVARCHAR(200),
    @concentracion      VARCHAR(50),
    @forma_farmaceutica VARCHAR(50),
    @registro_sanitario VARCHAR(50),
    @lote               VARCHAR(50),
    @fecha_fabricacion  DATE,
    @fecha_vencimiento  DATE,
    @stock              INT,
    @stock_minimo       INT = 10,
    @precio_compra      DECIMAL(12,2),
    @precio_venta       DECIMAL(12,2),
    @requiere_receta    BIT = 0,
    @estado             VARCHAR(20) = 'ACTIVO'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    INSERT INTO dbo.medicamentos
        (codigo, nombre_comercial, principio_activo, laboratorio, concentracion,
         forma_farmaceutica, registro_sanitario, lote, fecha_fabricacion, fecha_vencimiento,
         stock, stock_minimo, precio_compra, precio_venta, requiere_receta, estado)
    VALUES
        (@codigo, @nombre_comercial, @principio_activo, @laboratorio, @concentracion,
         @forma_farmaceutica, @registro_sanitario, @lote, @fecha_fabricacion, @fecha_vencimiento,
         @stock, @stock_minimo, @precio_compra, @precio_venta, @requiere_receta, @estado);

    DECLARE @id INT = CAST(SCOPE_IDENTITY() AS INT);
    SELECT * FROM dbo.vw_medicamentos WHERE id = @id;
END;
GO

-- PUT /api/medicamentos/{id}  (ADMIN). Exige la versión que se leyó.
CREATE OR ALTER PROCEDURE dbo.sp_medicamento_actualizar
    @id                 INT,
    @version            BINARY(8),
    @nombre_comercial   NVARCHAR(200),
    @principio_activo   NVARCHAR(200),
    @laboratorio        NVARCHAR(200),
    @concentracion      VARCHAR(50),
    @forma_farmaceutica VARCHAR(50),
    @registro_sanitario VARCHAR(50),
    @lote               VARCHAR(50),
    @fecha_fabricacion  DATE,
    @fecha_vencimiento  DATE,
    @stock              INT,
    @stock_minimo       INT,
    @precio_compra      DECIMAL(12,2),
    @precio_venta       DECIMAL(12,2),
    @requiere_receta    BIT,
    @estado             VARCHAR(20),
    @codigo             VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tc INT = @@TRANCOUNT;
    IF @tc = 0 BEGIN TRAN;

    DECLARE @ver BINARY(8), @estado_actual VARCHAR(10), @stock_actual INT,
            @codigo_actual VARCHAR(12), @nombre NVARCHAR(100), @msg NVARCHAR(300);

    -- 1) Bloqueo pesimista de la fila
    SELECT @ver = version, @estado_actual = estado, @stock_actual = stock,
           @codigo_actual = codigo, @nombre = nombre_comercial
      FROM dbo.medicamentos WITH (UPDLOCK, ROWLOCK)
     WHERE id = @id;

    IF @ver IS NULL
        THROW 52004, N'No existe el medicamento', 1;

    -- 2) Concurrencia optimista: ¿alguien lo modificó desde que lo leí?
    IF @ver <> @version
    BEGIN
        SET @msg = CONCAT(N'''', @nombre, N''' fue modificado por otro usuario. Recargue e intente de nuevo.');
        THROW 52001, @msg, 1;
    END;

    IF @codigo IS NOT NULL AND @codigo <> @codigo_actual
        THROW 52007, N'El código de un medicamento no se puede modificar', 1;

    IF @estado_actual = 'RETIRADO'
        THROW 52003, N'Un medicamento RETIRADO no se puede modificar', 1;

    IF @stock < @stock_actual AND @estado <> 'ACTIVO'
        THROW 52003, N'Solo se puede despachar stock de medicamentos ACTIVOS', 1;

    -- 3) Guardia final en el WHERE
    UPDATE dbo.medicamentos
       SET nombre_comercial = @nombre_comercial, principio_activo = @principio_activo,
           laboratorio = @laboratorio, concentracion = @concentracion,
           forma_farmaceutica = @forma_farmaceutica, registro_sanitario = @registro_sanitario,
           lote = @lote, fecha_fabricacion = @fecha_fabricacion,
           fecha_vencimiento = @fecha_vencimiento, stock = @stock, stock_minimo = @stock_minimo,
           precio_compra = @precio_compra, precio_venta = @precio_venta,
           requiere_receta = @requiere_receta, estado = @estado,
           actualizado_en = SYSDATETIME()
     WHERE id = @id AND version = @version;

    IF @@ROWCOUNT = 0
        THROW 52001, N'El registro cambió mientras se guardaba. Recargue.', 1;

    IF @tc = 0 COMMIT;
    SELECT * FROM dbo.vw_medicamentos WHERE id = @id;
END;
GO

-- PATCH /api/medicamentos/{id}/stock  (ADMIN y FARMACEUTICO)
-- ENTRADA suma, SALIDA (despacho) resta. N usuarios despachando a la vez
-- el mismo medicamento: el stock NUNCA queda negativo.
-- @demora_ms retiene el bloqueo (solo para que la espera se vea en la demo).
CREATE OR ALTER PROCEDURE dbo.sp_medicamento_mover_stock
    @id         INT,
    @operacion  VARCHAR(10),
    @cantidad   INT,
    @usuario_id INT,
    @servidor   VARCHAR(30) = NULL,
    @demora_ms  INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tc INT = @@TRANCOUNT;
    IF @tc = 0 BEGIN TRAN;

    DECLARE @stock INT, @estado VARCHAR(10), @vence DATE, @nombre NVARCHAR(100),
            @msg NVARCHAR(300);

    -- 1) Bloqueo pesimista: la segunda petición ESPERA aquí
    SELECT @stock = stock, @estado = estado, @vence = fecha_vencimiento, @nombre = nombre_comercial
      FROM dbo.medicamentos WITH (UPDLOCK, ROWLOCK)
     WHERE id = @id;

    IF @stock IS NULL
        THROW 52004, N'No existe el medicamento', 1;

    IF @demora_ms > 0
    BEGIN
        IF @demora_ms > 3000 SET @demora_ms = 3000;
        -- Formato hh:mm:ss.mmm  (ej. 1500 ms -> '00:00:01.500')
        DECLARE @espera VARCHAR(12) = CONCAT('00:00:0', @demora_ms / 1000, '.',
                                             RIGHT(CONCAT('00', @demora_ms % 1000), 3));
        WAITFOR DELAY @espera;
    END;

    DECLARE @delta INT = CASE WHEN @operacion = 'ENTRADA' THEN @cantidad ELSE -@cantidad END;

    IF @operacion = 'SALIDA'
    BEGIN
        IF @estado <> 'ACTIVO'
        BEGIN
            SET @msg = CONCAT(N'''', @nombre, N''' está ', @estado, N', no se puede despachar');
            THROW 52003, @msg, 1;
        END;
        IF @vence <= CAST(GETDATE() AS DATE)
        BEGIN
            SET @msg = CONCAT(N'''', @nombre, N''' está vencido, no se puede despachar');
            THROW 52005, @msg, 1;
        END;
        IF @stock < @cantidad
        BEGIN
            SET @msg = CASE WHEN @stock = 0
                            THEN CONCAT(N'Ya no hay stock de ''', @nombre, N'''. Otro usuario lo despachó.')
                            ELSE CONCAT(N'Stock insuficiente de ''', @nombre, N''': pidió ', @cantidad,
                                        N', quedan ', @stock, N'.') END;
            THROW 52002, @msg, 1;
        END;
    END
    ELSE IF @operacion = 'ENTRADA'
    BEGIN
        IF @estado = 'RETIRADO'
        BEGIN
            SET @msg = CONCAT(N'''', @nombre, N''' está RETIRADO');
            THROW 52003, @msg, 1;
        END;
        IF @stock + @cantidad > 100000
            THROW 52006, N'El stock no puede superar 100000', 1;
    END
    ELSE
        THROW 52006, N'Operación no válida (ENTRADA o SALIDA)', 1;

    -- 2) Guardia final: la condición vuelve a estar en el WHERE
    UPDATE dbo.medicamentos
       SET stock = stock + @delta, actualizado_en = SYSDATETIME()
     WHERE id = @id AND stock + @delta >= 0;

    IF @@ROWCOUNT = 0
    BEGIN
        SET @msg = CONCAT(N'Stock insuficiente de ''', @nombre, N'''');
        THROW 52002, @msg, 1;
    END;

    -- 3) Trazabilidad: quién lo hizo y qué API lo atendió
    INSERT INTO dbo.movimientos_stock
        (medicamento_id, usuario_id, operacion, cantidad, stock_anterior, stock_nuevo, servidor)
    VALUES (@id, @usuario_id, @operacion, @cantidad, @stock, @stock + @delta, @servidor);

    IF @tc = 0 COMMIT;
    SELECT @stock AS stock_anterior, v.* FROM dbo.vw_medicamentos v WHERE v.id = @id;
END;
GO

-- DELETE /api/medicamentos/{id}?version=N  (ADMIN) - baja LÓGICA
CREATE OR ALTER PROCEDURE dbo.sp_medicamento_baja
    @id      INT,
    @version BINARY(8)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tc INT = @@TRANCOUNT;
    IF @tc = 0 BEGIN TRAN;

    DECLARE @ver BINARY(8), @stock INT, @estado VARCHAR(10), @nombre NVARCHAR(100),
            @msg NVARCHAR(300);

    SELECT @ver = version, @stock = stock, @estado = estado, @nombre = nombre_comercial
      FROM dbo.medicamentos WITH (UPDLOCK, ROWLOCK)
     WHERE id = @id;

    IF @ver IS NULL
        THROW 52004, N'No existe el medicamento', 1;
    IF @ver <> @version
    BEGIN
        SET @msg = CONCAT(N'''', @nombre, N''' fue modificado por otro usuario. Recargue.');
        THROW 52001, @msg, 1;
    END;
    IF @stock > 0
    BEGIN
        SET @msg = CONCAT(N'No se puede dar de baja: aún tiene ', @stock, N' unidades en stock');
        THROW 52002, @msg, 1;
    END;
    IF @estado = 'INACTIVO'
        THROW 52003, N'El medicamento ya está inactivo', 1;

    UPDATE dbo.medicamentos
       SET estado = 'INACTIVO', actualizado_en = SYSDATETIME()
     WHERE id = @id AND version = @version;
    IF @@ROWCOUNT = 0
        THROW 52001, N'El registro cambió mientras se eliminaba. Recargue.', 1;

    IF @tc = 0 COMMIT;
    SELECT * FROM dbo.vw_medicamentos WHERE id = @id;
END;
GO

PRINT 'Vistas, funciones y procedimientos creados.';
GO
