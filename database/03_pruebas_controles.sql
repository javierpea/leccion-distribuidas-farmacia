/* =====================================================================
   PRUEBAS DE LOS CONTROLES DE LA BD - cada bloque DEBE FALLAR.
   (Para la exposición: muestra que la BD protege aunque no haya API)
     sqlcmd -S "(localdb)\MSSQLLocalDB" -E -f 65001 -i 03_pruebas_controles.sql
   ===================================================================== */
USE AppDistribuidas_2026_DB;
GO
SET NOCOUNT ON;

DECLARE @pruebas TABLE (n INT IDENTITY, prueba NVARCHAR(60), sql NVARCHAR(MAX));
INSERT INTO @pruebas (prueba, sql) VALUES
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
 (N'Borrar con stock',            N'DELETE FROM dbo.medicamentos WHERE codigo = ''MED-0001''');

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
            PRINT N'⚠ ' + @p + N': no afectó filas (¿cargó 02_datos.sql?)';
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
