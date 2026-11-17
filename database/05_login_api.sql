/* =====================================================================
   Usuario SQL para la API remota (entorno 2, IP_API2 en ips.env).
   Ejecutar en el equipo de la BD, sobre SQL Server Express:
     sqlcmd -S "localhost\SQLEXPRESS" -E -I -f 65001 -i 05_login_api.sql

   Mínimo privilegio: la API solo puede LEER las vistas y EJECUTAR los
   procedimientos. No puede tocar las tablas directamente (ni ver los
   hash de las contraseñas).
   ===================================================================== */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
USE master;
IF SUSER_ID('farmacia_app') IS NULL
    CREATE LOGIN farmacia_app WITH PASSWORD = 'Farmacia2026*', CHECK_POLICY = OFF;
GO
USE AppDistribuidas_2026_DB;
IF USER_ID('farmacia_app') IS NULL
    CREATE USER farmacia_app FOR LOGIN farmacia_app;
GO
-- Por si quedó el permiso directo sobre la tabla de la versión anterior
REVOKE SELECT, INSERT, UPDATE, DELETE ON dbo.medicamentos FROM farmacia_app;
GO
GRANT EXECUTE ON SCHEMA::dbo TO farmacia_app;
GRANT SELECT ON dbo.vw_medicamentos         TO farmacia_app;
GRANT SELECT ON dbo.vw_catalogo             TO farmacia_app;
GRANT SELECT ON dbo.vw_medicamentos_alertas TO farmacia_app;
GRANT SELECT ON dbo.vw_usuarios             TO farmacia_app;
GRANT SELECT ON dbo.vw_movimientos_stock    TO farmacia_app;
GO
-- Activar autenticación mixta (SQL + Windows). Requiere reiniciar el servicio.
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
     N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2;
GO
PRINT 'Login farmacia_app listo. Reiniciar el servicio:  Restart-Service ''MSSQL$SQLEXPRESS''';
GO
