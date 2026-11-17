/// Usuario del sistema (tabla dbo.usuarios, vista dbo.vw_usuarios).
class Usuario {
  final int id;
  final String usuario;
  final String nombreCompleto;
  final String? email;

  /// ADMIN | FARMACEUTICO | CLIENTE
  final String rol;

  /// LOCAL | GOOGLE | FACEBOOK
  final String proveedor;

  // Solo vienen en la pantalla de administración de usuarios
  final bool estado;
  final bool bloqueado;
  final DateTime? ultimoAcceso;
  final int version;

  const Usuario({
    required this.id,
    required this.usuario,
    required this.nombreCompleto,
    required this.email,
    required this.rol,
    required this.proveedor,
    this.estado = true,
    this.bloqueado = false,
    this.ultimoAcceso,
    this.version = 0,
  });

  bool get esAdmin => rol == 'ADMIN';
  bool get esFarmaceutico => rol == 'FARMACEUTICO';
  bool get esCliente => rol == 'CLIENTE';

  /// ADMIN y FARMACEUTICO ven el inventario completo
  bool get esPersonal => esAdmin || esFarmaceutico;
  bool get esSocial => proveedor != 'LOCAL';

  String get rolLegible => switch (rol) {
        'ADMIN' => 'Administrador',
        'FARMACEUTICO' => 'Farmacéutico',
        _ => 'Cliente',
      };

  factory Usuario.fromJson(Map<String, dynamic> j) => Usuario(
        id: (j['id'] as num).toInt(),
        usuario: j['usuario'] as String,
        nombreCompleto: j['nombre_completo'] as String,
        email: j['email'] as String?,
        rol: j['rol'] as String,
        proveedor: (j['proveedor'] as String?) ?? 'LOCAL',
        estado: (j['estado'] as bool?) ?? true,
        bloqueado: (j['bloqueado'] as bool?) ?? false,
        ultimoAcceso: j['ultimo_acceso'] == null
            ? null
            : DateTime.parse(j['ultimo_acceso'] as String),
        version: (j['version'] as num?)?.toInt() ?? 0,
      );
}
