/// Medicamento tal como lo ve el CLIENTE (vista dbo.vw_catalogo):
/// sin precio de compra, lote, registro sanitario ni stock exacto.
class ItemCatalogo {
  final int id;
  final String codigo;
  final String nombreComercial;
  final String principioActivo;
  final String laboratorio;
  final String concentracion;
  final String formaFarmaceutica;
  final DateTime fechaVencimiento;
  final double precioVenta;
  final bool requiereReceta;
  final bool disponible;

  const ItemCatalogo({
    required this.id,
    required this.codigo,
    required this.nombreComercial,
    required this.principioActivo,
    required this.laboratorio,
    required this.concentracion,
    required this.formaFarmaceutica,
    required this.fechaVencimiento,
    required this.precioVenta,
    required this.requiereReceta,
    required this.disponible,
  });

  factory ItemCatalogo.fromJson(Map<String, dynamic> j) => ItemCatalogo(
        id: (j['id'] as num).toInt(),
        codigo: j['codigo'] as String,
        nombreComercial: j['nombre_comercial'] as String,
        principioActivo: j['principio_activo'] as String,
        laboratorio: j['laboratorio'] as String,
        concentracion: j['concentracion'] as String,
        formaFarmaceutica: j['forma_farmaceutica'] as String,
        fechaVencimiento: DateTime.parse(j['fecha_vencimiento'] as String),
        precioVenta: (j['precio_venta'] as num).toDouble(),
        requiereReceta: j['requiere_receta'] as bool,
        disponible: j['disponible'] as bool,
      );
}

/// Movimiento de stock (vista dbo.vw_movimientos_stock).
class Movimiento {
  final DateTime fecha;
  final String operacion;
  final int cantidad;
  final int stockAnterior;
  final int stockNuevo;
  final String usuario;
  final String? servidor;

  const Movimiento({
    required this.fecha,
    required this.operacion,
    required this.cantidad,
    required this.stockAnterior,
    required this.stockNuevo,
    required this.usuario,
    this.servidor,
  });

  factory Movimiento.fromJson(Map<String, dynamic> j) => Movimiento(
        fecha: DateTime.parse(j['fecha'] as String),
        operacion: j['operacion'] as String,
        cantidad: (j['cantidad'] as num).toInt(),
        stockAnterior: (j['stock_anterior'] as num).toInt(),
        stockNuevo: (j['stock_nuevo'] as num).toInt(),
        usuario: j['usuario'] as String,
        servidor: j['servidor'] as String?,
      );
}
