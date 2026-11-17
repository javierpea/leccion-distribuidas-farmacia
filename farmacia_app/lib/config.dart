import 'config_red.dart';

/// Configuración del cliente.
///
/// El cliente SOLO conoce la IP VIRTUAL de Keepalived (config_red.dart,
/// generado desde ips.env con `python aplicar_ips.py`). Nunca apunta
/// directo a un Flask: NGINX (en el nodo que tenga la IP virtual) reparte
/// entre las dos APIs.
class AppConfig {
  static const String ipVirtualPorDefecto = 'http://$ipVirtual:$puertoNginx';

  /// El administrador puede cambiarla en tiempo de ejecución (ícono ⚙)
  /// para probar directo contra un Flask, p. ej. http://IP_API1:5000
  static String baseUrl = ipVirtualPorDefecto;

  /// Tiempo máximo por petición. Las consultas se reintentan una vez
  /// (ver ApiService) para que un failover de Keepalived no se note.
  static const Duration timeout = Duration(seconds: 6);
}
