import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/oauth_service.dart';
import '../utils/validadores.dart';
import '../widgets/botones_sociales.dart';

/// Registro público: SIEMPRE crea una cuenta de CLIENTE (el rol lo
/// asigna la BD en sp_usuario_registrar, no la app). Al terminar, la
/// sesión queda iniciada y devuelve el Usuario a la pantalla de login.
class RegistroPage extends StatefulWidget {
  const RegistroPage({super.key});

  @override
  State<RegistroPage> createState() => _RegistroPageState();
}

class _RegistroPageState extends State<RegistroPage> {
  final _form = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _usuario = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmar = TextEditingController();
  bool _verClave = false;
  bool _guardando = false;
  String? _mensaje;
  Map<String, String> _erroresServidor = {};

  @override
  void dispose() {
    for (final c in [_nombre, _usuario, _email, _password, _confirmar]) {
      c.dispose();
    }
    super.dispose();
  }

  String? Function(String?) _v(String campo, String? Function(String?) local) =>
      (valor) => local(valor) ?? _erroresServidor[campo];

  Future<void> _registrar() async {
    setState(() {
      _erroresServidor = {};
      _mensaje = null;
    });
    if (!_form.currentState!.validate()) return;
    setState(() => _guardando = true);
    try {
      final u = await ApiService.registro({
        'nombre_completo': Validadores.limpiar(_nombre.text),
        'usuario': _usuario.text.trim(),
        'email': _email.text.trim().isEmpty ? null : _email.text.trim(),
        'password': _password.text,
      });
      if (mounted) Navigator.pop(context, u);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _erroresServidor = e.errores;
        _mensaje = e.mensaje;
      });
      _form.currentState!.validate(); // pinta los errores del servidor
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// Crear la cuenta con Google o Facebook (queda como CLIENTE).
  Future<void> _registrarCon(String proveedor) async {
    setState(() {
      _guardando = true;
      _mensaje = null;
    });
    try {
      final u = await OAuthService.iniciarSesion(proveedor);
      if (mounted) Navigator.pop(context, u);
    } on ApiException catch (e) {
      if (mounted) setState(() => _mensaje = e.mensaje);
    } catch (e) {
      if (mounted) setState(() => _mensaje = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Widget _campo(String campo, String etiqueta, TextEditingController c,
      {required String? Function(String?) validar,
      required List<TextInputFormatter> fmt,
      IconData? icono,
      String? ayuda,
      bool clave = false,
      TextInputType teclado = TextInputType.text,
      TextCapitalization cap = TextCapitalization.none}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: c,
        obscureText: clave && !_verClave,
        keyboardType: teclado,
        textCapitalization: cap,
        inputFormatters: fmt,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        decoration: InputDecoration(
          labelText: etiqueta,
          helperText: ayuda,
          prefixIcon: icono == null ? null : Icon(icono),
          border: const OutlineInputBorder(),
          suffixIcon: clave
              ? IconButton(
                  icon: Icon(_verClave ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _verClave = !_verClave))
              : null,
        ),
        validator: _v(campo, validar),
        onChanged: (_) {
          if (_erroresServidor.containsKey(campo)) {
            setState(() => _erroresServidor.remove(campo));
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crear cuenta')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _form,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_mensaje != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(padding: const EdgeInsets.all(12), child: Text(_mensaje!)),
                  ),
                const SizedBox(height: 8),
                _campo('nombre_completo', 'Nombre completo', _nombre,
                    icono: Icons.badge_outlined,
                    ayuda: 'Solo letras',
                    cap: TextCapitalization.words,
                    fmt: [...Validadores.soloLetrasFmt, LengthLimitingTextInputFormatter(100)],
                    validar: (v) => Validadores.soloLetras(v, 'Nombre', 3, 100)),
                _campo('usuario', 'Usuario', _usuario,
                    icono: Icons.person_outline,
                    ayuda: 'Minúsculas, números, punto o guion bajo',
                    fmt: Validadores.usuarioFmt,
                    validar: Validadores.usuario),
                _campo('email', 'Correo (opcional)', _email,
                    icono: Icons.alternate_email,
                    teclado: TextInputType.emailAddress,
                    fmt: Validadores.emailFmt,
                    validar: (v) => Validadores.email(v)),
                _campo('password', 'Contraseña', _password,
                    icono: Icons.lock_outline,
                    ayuda: '8 a 50, con letras y números',
                    clave: true,
                    fmt: Validadores.passwordFmt,
                    validar: (v) => Validadores.password(v)),
                _campo('confirmar', 'Repetir contraseña', _confirmar,
                    icono: Icons.lock_reset,
                    clave: true,
                    fmt: Validadores.passwordFmt,
                    validar: (v) => v != _password.text ? 'Las contraseñas no coinciden' : null),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _guardando ? null : _registrar,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: _guardando
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.how_to_reg),
                  label: const Text('CREAR CUENTA'),
                ),
                const SizedBox(height: 20),
                BotonesSociales(
                  accion: 'Registrarse con',
                  habilitado: !_guardando,
                  alElegir: _registrarCon,
                ),
                const SizedBox(height: 12),
                const Text('Las cuentas nuevas son de tipo Cliente.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
