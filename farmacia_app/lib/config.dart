/// Configuración del cliente.
///
/// El cliente SOLO conoce la IP VIRTUAL de Keepalived. Nunca apunta
/// directo a un Flask: Nginx (en el nodo que tenga la VIP) balancea
/// entre 10.79.5.86:5000 y 10.79.4.177:5001 (puerto 90).
class AppConfig {
  static const String ipVirtualPorDefecto = 'http://10.79.7.200:90';

  /// Se puede cambiar en tiempo de ejecución (ícono ⚙ en la lista)
  /// para probar directo contra un Flask, p. ej. http://10.79.5.86:5000
  static String baseUrl = ipVirtualPorDefecto;

  static const Duration timeout = Duration(seconds: 15);
}
