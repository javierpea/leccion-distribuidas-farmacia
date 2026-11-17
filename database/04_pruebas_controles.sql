/* =====================================================================
   PRUEBAS DE LOS CONTROLES DE LA BD - cada bloque DEBE FALLAR.
   (Para la exposición: muestra que la BD protege aunque no haya API)
     sqlcmd -S "localhost\SQLEXPRESS" -E -I -f 65001 -i 04_pruebas_controles.sql
   Todo se hace dentro de una transacción que se deshace: no cambia datos.
   ===================================================================== */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
USE AppDistribuidas_2026_DB;
GO
SET NOCOUNT ON;

DECLARE @pruebas TABLE (n INT IDENTITY, prueba NVARCHAR(60), sql NVARCHAR(MAX));
INSERT INTO @pruebas (prueba, sql) VALUES
 -- ---------------- MEDICAMENTOS ----------------
 (N'Nombre duplicado (mayúsc./tildes)',
  N'INSERT INTO dbo.medicamentos (codigo,nombre_comercial,principio_activo,laboratorio,concentracion,forma_farmaceutica,registro_sanitario,lote,fecha_fabricacion,fecha_vencimiento,stock,precio_compra,precio_venta)
    VALUES (''MED-0099'',N''PARACETÁMOL GENFAR'',N''Paracetamol'',N''Genfar'',''500 mg'',''TABLETA'',''9999-XX'',''L9999'',''2026-01-01'',''2028-01-01'',5,0.05,0.10)'),
 (N'Stock negativo',              N'UPDATE dbo.medicamentos SET stock = -5 WHERE codigo = ''MED-0001'''),
 (N'Números en el nombre',        N'UPDATE dbo.medicamentos SET nombre_comercial = N''Paracetamol 500'' WHERE codigo = ''MED-0001'''),
 (N'Símbolos en el laboratorio',  N'UPDATE dbo.medicamentos SET laboratorio = N''Genfar$'' WHERE codigo = ''MED-0001'''),
 (N'Precio venta < compra',       N'UPDATE dbo.medicamentos SET precio_venta = 0.01 WHERE codigo = ''MED-0001'''),
 (N'Precio 0',                    N'UPDATE dbo.medicamentos SET precio_compra = 0 WHERE codigo = ''MED-0001'''),
 (N'Texto en el stock',           N'UPDATE dbo.medicamentos SET stock = ''diez'' WHERE codigo = ''MED-0001'''),
 (N'Código inválido',             N'UPDATE dbo.medicamentos SET codigo = ''ABC'' WHERE codigo = ''MED-0001'''),
 (N'Cambiar el código',           N'UPDATE dbo.medicamentos SET codigo = ''MED-0998'' WHERE codigo = ''MED-0001'''),
 (N'Lote con minúsculas/espacios',N'UPDATE dbo.medicamentos SET lote = ''l 2026'' WHERE codigo = ''MED-0001'''),
 (N'Concentración inválida',      N'UPDATE dbo.medicamentos SET concentracion = ''mucho'' WHERE codigo = ''MED-0001'''),
 (N'Vencimiento antes de fabric.',N'UPDATE dbo.medicamentos SET fecha_vencimiento = ''2020-01-01'' WHERE codigo = ''MED-0001'''),
 (N'Estado no válido',            N'UPDATE dbo.medicamentos SET estado = ''BORRADO'' WHERE codigo = ''MED-0001'''),
 (N'Borrar con stock',            N'DELETE FROM dbo.medicamentos WHERE codigo = ''MED-0001'''),
 (N'SP: despachar más del stock', N'DECLARE @id INT = (SELECT id FROM dbo.medicamentos WHERE codigo = ''MED-0020'');
                                    DECLARE @u INT = (SELECT id FROM dbo.usuarios WHERE usuario = ''farmaceutico'');
                                    EXEC dbo.sp_medicamento_mover_stock @id, ''SALIDA'', 999, @u'),
 (N'SP: actualizar con versión vieja', N'DECLARE @id INT = (SELECT id FROM dbo.medicamentos WHERE codigo = ''MED-0001'');
                                    EXEC dbo.sp_medicamento_actualizar @id = @id, @version = 0x0000000000000001,
                                      @nombre_comercial = N''Paracetamol Genfar'', @principio_activo = N''Paracetamol'',
                                      @laboratorio = N''Genfar'', @concentracion = ''500 mg'', @forma_farmaceutica = ''TABLETA'',
                                      @registro_sanitario = ''1234-MEE-0521'', @lote = ''L2026A01'',
                                      @fecha_fabricacion = ''2026-01-10'', @fecha_vencimiento = ''2028-01-10'',
                                      @stock = 1, @stock_minimo = 30, @precio_compra = 0.05, @precio_venta = 0.10,
                                      @requiere_receta = 0, @estado = ''ACTIVO'''),
 (N'Movimiento de stock que no cuadra', N'INSERT INTO dbo.movimientos_stock (medicamento_id, usuario_id, operacion, cantidad, stock_anterior, stock_nuevo)
                                    SELECT TOP 1 m.id, u.id, ''SALIDA'', 5, 10, 8 FROM dbo.medicamentos m CROSS JOIN dbo.usuarios u'),
 -- ---------------- USUARIOS ----------------
 (N'Usuario repetido',            N'EXEC dbo.sp_usuario_registrar ''admin'', N''Clave1234'', N''Otro Admin'''),
 (N'Usuario con mayúsculas/espacios', N'UPDATE dbo.usuarios SET usuario = ''Juan Perez'' WHERE usuario = ''cliente'''),
 (N'Cambiar nombre de usuario',   N'UPDATE dbo.usuarios SET usuario = ''cliente.nuevo'' WHERE usuario = ''cliente'''),
 (N'Nombre completo con números', N'UPDATE dbo.usuarios SET nombre_completo = N''Juan 123'' WHERE usuario = ''cliente'''),
 (N'Correo inválido',             N'UPDATE dbo.usuarios SET email = ''correo-sin-arroba'' WHERE usuario = ''cliente'''),
 (N'Correo repetido',             N'UPDATE dbo.usuarios SET email = ''admin@farmacia.com'' WHERE usuario = ''cliente'''),
 (N'Rol no válido',               N'UPDATE dbo.usuarios SET rol = ''SUPERADMIN'' WHERE usuario = ''cliente'''),
 (N'Cuenta LOCAL sin contraseña', N'UPDATE dbo.usuarios SET password_hash = NULL WHERE usuario = ''cliente'''),
 (N'Contraseña débil',            N'EXEC dbo.sp_usuario_registrar ''nuevo.usuario'', N''123'', N''Nuevo Usuario'''),
 (N'Desactivar al único admin',   N'UPDATE dbo.usuarios SET estado = 0 WHERE usuario = ''admin'''),
 (N'Token que ya expiró',         N'INSERT INTO dbo.tokens (usuario_id, token_hash, fecha_creacion, fecha_expiracion)
                                    SELECT id, HASHBYTES(''SHA2_256'', ''x''), SYSDATETIME(), DATEADD(MINUTE, -1, SYSDATETIME())
                                      FROM dbo.usuarios WHERE usuario = ''admin''');

DECLARE @i INT = 1, @max INT = (SELECT MAX(n) FROM @pruebas), @p NVARCHAR(60), @s NVARCHAR(MAX);
WHILE @i <= @max
BEGIN
    SELECT @p = prueba, @s = sql FROM @pruebas WHERE n = @i;
    BEGIN TRY
        DECLARE @filas INT;
        BEGIN TRAN;
        EXEC sp_executesql @s;
        SET @filas = @@ROWCOUNT;
        ROLLBACK;
        IF @filas = 0
            PRINT N'⚠ ' + @p + N': no afectó filas (¿cargó 03_datos.sql?)';
        ELSE
            PRINT N'❌ ' + @p + N': ACEPTADO (no debería)';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        PRINT N'✅ ' + @p + N': RECHAZADO -> ' + LEFT(ERROR_MESSAGE(), 110);
    END CATCH;
    SET @i += 1;
END;
GO

-- Login: contraseña incorrecta (no da token) y token inventado (no valida)
PRINT N'--- Login ---';
BEGIN TRAN;
EXEC dbo.sp_auth_login @usuario = 'admin', @password = N'Incorrecta1';
EXEC dbo.sp_auth_validar_token @token = 'TOKENINVENTADO';
ROLLBACK;
GO
