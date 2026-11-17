import 'dart:async';

import 'package:flutter/material.dart';

import '../config.dart';
import '../services/api_service.dart';

/// Se muestra encima de toda la app cuando NINGÚN servidor responde
/// (los 3 nodos caídos, o Nginx vivo pero sin Flask / sin BD).
/// Reintenta cada 5 s y se cierra sola cuando un servidor vuelve.
class MantenimientoPage extends StatefulWidget {
  const MantenimientoPage({super.key});

  @override
  State<MantenimientoPage> createState() => _MantenimientoPageState();
}

class _MantenimientoPageState extends State<MantenimientoPage> {
  static const _intervalo = 5;
  Timer? _timer;
  int _segundos = _intervalo;
  int _intentos = 0;
  bool _probando = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_probando) return;
      if (_segundos <= 1) {
        _reintentar();
      } else {
        setState(() => _segundos--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reintentar() async {
    setState(() => _probando = true);
    // Si responde, ApiService.enMantenimiento pasa a false y esta
    // pantalla desaparece automáticamente.
    await ApiService.health();
    if (!mounted) return;
    setState(() {
      _probando = false;
      _intentos++;
      _segundos = _intervalo;
    });
  }

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: esquema.surface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.engineering, size: 96, color: esquema.primary),
                const SizedBox(height: 24),
                Text('Sistema en mantenimiento',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                const Text(
                  'Los servidores de la farmacia no están disponibles en este momento. '
                  'Estamos trabajando para restablecer el servicio.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_probando)
                  const Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text('Comprobando servidores...'),
                  ])
                else
                  Text('Reintentando en $_segundos s  ·  intentos: $_intentos'),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _probando ? null : _reintentar,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar ahora'),
                ),
                const SizedBox(height: 24),
                Text(AppConfig.baseUrl,
                    style: TextStyle(fontSize: 12, color: esquema.outline)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
