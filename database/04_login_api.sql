/* =====================================================================
   Usuario SQL para la API remota (Server 1 - API :5001).
   Ejecutar en el CLIENTE, sobre SQL Server Express:
     sqlcmd -S "localhost\SQLEXPRESS" -E -i 04_login_api.sql
   ===================================================================== */
USE master;
IF SUSER_ID('farmacia_app') IS NULL
    CREATE LOGIN farmacia_app WITH PASSWORD = 'Farmacia2026*', CHECK_POLICY = OFF;
GO
USE AppDistribuidas_2026_DB;
IF USER_ID('farmacia_app') IS NULL
    CREATE USER farmacia_app FOR LOGIN farmacia_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.medicamentos TO farmacia_app;
GO
-- Activar autenticación mixta (SQL + Windows). Requiere reiniciar el servicio.
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
     N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2;
GO
PRINT 'Login farmacia_app listo. Reiniciar el servicio SQL Server (SQLEXPRESS).';
GO
