/* =====================================================================
   Datos de prueba (20 medicamentos)
     sqlcmd -S "(localdb)\MSSQLLocalDB" -E -f 65001 -i 02_datos.sql
   ===================================================================== */
USE AppDistribuidas_2026_DB;
GO
SET NOCOUNT ON;

INSERT INTO dbo.medicamentos
 (codigo, nombre_comercial, principio_activo, laboratorio, concentracion, forma_farmaceutica,
  registro_sanitario, lote, fecha_fabricacion, fecha_vencimiento, stock, stock_minimo,
  precio_compra, precio_venta, requiere_receta)
VALUES
 ('MED-0001',N'Paracetamol Genfar',N'Paracetamol',N'Genfar','500 mg','TABLETA','1234-MEE-0521','L2026A01','2026-01-10','2028-01-10',250,30,0.05,0.10,0),
 ('MED-0002',N'Ibuprofeno MK',N'Ibuprofeno',N'Tecnoquimicas','400 mg','TABLETA','2211-MEE-0322','L2026A02','2026-02-15','2028-02-15',180,25,0.08,0.15,0),
 ('MED-0003',N'Amoxicilina La Sante',N'Amoxicilina',N'La Sante','500 mg','CAPSULA','3145-MEE-0623','L2026B01','2026-03-01','2027-09-01',120,20,0.12,0.25,1),
 ('MED-0004',N'Loratadina Bago',N'Loratadina',N'Bago','10 mg','TABLETA','4120-MEE-0124','L2026B02','2026-01-20','2028-01-20',90,15,0.07,0.18,0),
 ('MED-0005',N'Omeprazol Pharmabrand',N'Omeprazol',N'Pharmabrand','20 mg','CAPSULA','5098-MEE-0225','L2026C01','2026-04-05','2028-04-05',200,30,0.06,0.14,0),
 ('MED-0006',N'Azitromicina Roemmers',N'Azitromicina',N'Roemmers','500 mg','TABLETA','6011-MEE-0326','L2026C02','2026-02-28','2027-12-31',60,10,0.90,1.80,1),
 ('MED-0007',N'Salbutamol Inhalador',N'Salbutamol',N'Glaxo','100 mcg','SUSPENSION','7012-MEE-0427','L2026D01','2026-05-10','2028-05-10',40,8,3.50,6.25,1),
 ('MED-0008',N'Jarabe Ambroxol',N'Ambroxol',N'Siegfried','15 mg/5 ml','JARABE','8013-MEE-0528','L2026D02','2026-06-01','2027-12-01',75,10,2.10,3.90,0),
 ('MED-0009',N'Diclofenaco Gel',N'Diclofenaco',N'Novartis','1 %','CREMA','9014-MEE-0629','L2026E01','2026-03-12','2028-03-12',55,10,2.80,4.75,0),
 ('MED-0010',N'Losartán Medicamenta',N'Losartán',N'Medicamenta','50 mg','TABLETA','1015-MEE-0730','L2026E02','2026-04-18','2028-04-18',300,40,0.10,0.22,1),
 ('MED-0011',N'Metformina Sanofi',N'Metformina',N'Sanofi','850 mg','TABLETA','1116-MEE-0831','L2026F01','2026-05-22','2028-05-22',260,40,0.09,0.20,1),
 ('MED-0012',N'Enalapril Lamosan',N'Enalapril',N'Lamosan','10 mg','TABLETA','1217-MEE-0932','L2026F02','2026-02-02','2028-02-02',140,20,0.06,0.13,1),
 ('MED-0013',N'Cetirizina Gotas',N'Cetirizina',N'Bayer','10 mg/ml','GOTAS','1318-MEE-1033','L2026G01','2026-07-07','2028-07-07',35,8,3.20,5.60,0),
 ('MED-0014',N'Suero Oral',N'Sales de rehidratación',N'Life','27.9 g','POLVO','1419-MEE-1134','L2026G02','2026-06-15','2028-06-15',95,15,0.40,0.85,0),
 ('MED-0015',N'Ketorolaco Inyectable',N'Ketorolaco',N'Roche','30 mg/ml','INYECTABLE','1520-MEE-1235','L2026H01','2026-08-01','2028-08-01',25,5,1.20,2.50,1),
 ('MED-0016',N'Clotrimazol Crema',N'Clotrimazol',N'Grünenthal','1 %','CREMA','1621-MEE-1336','L2026H02','2026-03-30','2028-03-30',48,8,1.90,3.40,0),
 ('MED-0017',N'Atorvastatina Pfizer',N'Atorvastatina',N'Pfizer','20 mg','TABLETA','1722-MEE-1437','L2026J01','2026-09-09','2028-09-09',110,20,0.25,0.55,1),
 ('MED-0018',N'Vitamina C Efervescente',N'Ácido ascórbico',N'Bayer','1 g','TABLETA','1823-MEE-1538','L2026J02','2026-04-04','2027-10-04',160,25,0.18,0.40,0),
 ('MED-0019',N'Dexametasona Ampolla',N'Dexametasona',N'Sanderson','4 mg/ml','INYECTABLE','1924-MEE-1639','L2026K01','2026-10-01','2028-10-01',8,10,0.70,1.50,1),
 ('MED-0020',N'Prueba Concurrencia',N'Paracetamol',N'Genfar','500 mg','TABLETA','2025-MEE-1740','L2026K02','2026-10-10','2028-10-10',10,2,0.05,0.10,0);

DECLARE @total INT = (SELECT COUNT(*) FROM dbo.medicamentos);
PRINT 'Datos cargados: ' + CAST(@total AS VARCHAR(10)) + ' medicamentos';
GO
/* MED-0019 queda bajo stock mínimo (alertas).
   MED-0020 tiene 10 unidades: úsenlo para la prueba de concurrencia. */
