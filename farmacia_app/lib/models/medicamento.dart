class Medicamento {
  final int id;
  final String codigo;
  final String nombreComercial;
  final String principioActivo;
  final String laboratorio;
  final String concentracion;
  final String formaFarmaceutica;
  final String registroSanitario;
  final String lote;
  final DateTime fechaFabricacion;
  final DateTime fechaVencimiento;
  final int stock;
  final int stockMinimo;
  final double precioCompra;
  final double precioVenta;
  final bool requiereReceta;
  final String estado;

  /// Versión de la fila (concurrencia optimista). Se envía en PUT/DELETE.
  final int version;

  Medicamento({
    required this.id,
    required this.codigo,
    required this.nombreComercial,
    required this.principioActivo,
    required this.laboratorio,
    required this.concentracion,
    required this.formaFarmaceutica,
    required this.registroSanitario,
    required this.lote,
    required this.fechaFabricacion,
    required this.fechaVencimiento,
    required this.stock,
    required this.stockMinimo,
    required this.precioCompra,
    required this.precioVenta,
    required this.requiereReceta,
    required this.estado,
    required this.version,
  });

  bool get stockBajo => stock <= stockMinimo;
  bool get porVencer =>
      fechaVencimiento.difference(DateTime.now()).inDays <= 60;

  factory Medicamento.fromJson(Map<String, dynamic> j) => Medicamento(
        id: (j['id'] as num).toInt(),
        codigo: j['codigo'] as String,
        nombreComercial: j['nombre_comercial'] as String,
        principioActivo: j['principio_activo'] as String,
        laboratorio: j['laboratorio'] as String,
        concentracion: j['concentracion'] as String,
        formaFarmaceutica: j['forma_farmaceutica'] as String,
        registroSanitario: j['registro_sanitario'] as String,
        lote: j['lote'] as String,
        fechaFabricacion: DateTime.parse(j['fecha_fabricacion'] as String),
        fechaVencimiento: DateTime.parse(j['fecha_vencimiento'] as String),
        stock: (j['stock'] as num).toInt(),
        stockMinimo: (j['stock_minimo'] as num).toInt(),
        precioCompra: (j['precio_compra'] as num).toDouble(),
        precioVenta: (j['precio_venta'] as num).toDouble(),
        requiereReceta: j['requiere_receta'] as bool,
        estado: j['estado'] as String,
        version: (j['version'] as num).toInt(),
      );

  /// Cuerpo para PUT (incluye la versión leída).
  Map<String, dynamic> toJsonActualizar() => {
        'nombre_comercial': nombreComercial,
        'principio_activo': principioActivo,
        'laboratorio': laboratorio,
        'concentracion': concentracion,
        'forma_farmaceutica': formaFarmaceutica,
        'registro_sanitario': registroSanitario,
        'lote': lote,
        'fecha_fabricacion': fechaIso(fechaFabricacion),
        'fecha_vencimiento': fechaIso(fechaVencimiento),
        'stock': stock,
        'stock_minimo': stockMinimo,
        'precio_compra': precioCompra,
        'precio_venta': precioVenta,
        'requiere_receta': requiereReceta,
        'estado': estado,
        'version': version,
      };
}

String fechaIso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
