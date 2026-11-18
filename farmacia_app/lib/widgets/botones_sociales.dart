import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// Botones "Continuar con Google (Gmail)" y "Continuar con Facebook".
/// Se usan en el login y en "Crear cuenta". Siempre se muestran; si la
/// API aún no tiene las claves, al tocarlos aparece un aviso corto.
class BotonesSociales extends StatelessWidget {
  /// Texto antes del proveedor: "Continuar con" o "Registrarse con"
  final String accion;
  final bool habilitado;
  final void Function(String proveedor) alElegir; // GOOGLE | FACEBOOK

  const BotonesSociales({
    super.key,
    required this.alElegir,
    this.accion = 'Continuar con',
    this.habilitado = true,
  });

  Widget _boton(String proveedor, String texto, Widget icono) => OutlinedButton.icon(
        onPressed: habilitado ? () => alElegir(proveedor) : null,
        icon: icono,
        label: Text('$accion $texto'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          textStyle: const TextStyle(fontSize: 15),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Row(children: [
        Expanded(child: Divider()),
        Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('o')),
        Expanded(child: Divider()),
      ]),
      const SizedBox(height: 12),
      _boton('GOOGLE', 'Google (Gmail)',
          const FaIcon(FontAwesomeIcons.google, color: Color(0xFFDB4437), size: 20)),
      const SizedBox(height: 10),
      _boton('FACEBOOK', 'Facebook',
          const FaIcon(FontAwesomeIcons.facebook, color: Color(0xFF1877F2), size: 22)),
    ]);
  }
}
