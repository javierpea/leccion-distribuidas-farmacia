import 'package:flutter/material.dart';

import '../models/usuario.dart';
import '../navegacion.dart';
import '../services/api_service.dart';
import '../services/oauth_service.dart';
import '../utils/validadores.dart';
import '../widgets/botones_sociales.dart';
import 'registro_page.dart';

/// Pantalla de inicio de sesión (Unidad 3 - Práctica Final, Parte 3).
///  1. Envía usuario y contraseña   2. Recibe el token
///  3. Guarda el token (Sesion)     4. Entra según su rol
class LoginPage extends StatefulWidget {
  /// Mensaje para mostrar arriba (p. ej. "Sesión expirada").
  final String? mensaje;
  const LoginPage({super.key, this.mensaje});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _usuario = TextEditingController();
  final _password = TextEditingController();
  bool _verClave = false;
  bool _cargando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargarConfig();
  }

  @override
  void dispose() {
    _usuario.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Al abrir el login se consulta la API: si no hay ningún servidor
  /// disponible, la app muestra la pantalla de mantenimiento.
  Future<void> _cargarConfig() async {
    try {
      await ApiService.configLogin();
    } on ApiException {
      // la pantalla de mantenimiento se encarga
    }
  }

  Future<void> _ingresar() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final u = await ApiService.login(_usuario.text.trim(), _password.text);
      irAInicio(u);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _ingresarCon(String proveedor) async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final u = await OAuthService.iniciarSesion(proveedor);
      irAInicio(u);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _registrarse() async {
    final u = await Navigator.push<Usuario>(
        context, MaterialPageRoute(builder: (_) => const RegistroPage()));
    if (u != null) irAInicio(u);
  }

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.local_pharmacy, size: 72, color: esquema.primary),
                    const SizedBox(height: 8),
                    Text('Farmacia G3',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 4),
                    const Text('Inicie sesión para continuar', textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    if (widget.mensaje != null && _error == null)
                      Card(
                        color: esquema.secondaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(children: [
                            const Icon(Icons.info_outline),
                            const SizedBox(width: 8),
                            Expanded(child: Text(widget.mensaje!)),
                          ]),
                        ),
                      ),
                    if (_error != null)
                      Card(
                        color: esquema.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(children: [
                            const Icon(Icons.error_outline),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_error!)),
                          ]),
                        ),
                      ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _usuario,
                      enabled: !_cargando,
                      inputFormatters: Validadores.loginFmt,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Usuario o correo',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Ingrese su usuario o correo' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      enabled: !_cargando,
                      obscureText: !_verClave,
                      inputFormatters: Validadores.passwordFmt,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _ingresar(),
                      decoration: InputDecoration(
                        labelText: 'Contraseña',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _verClave ? 'Ocultar' : 'Mostrar',
                          icon: Icon(_verClave ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _verClave = !_verClave),
                        ),
                      ),
                      validator: (v) => (v ?? '').isEmpty ? 'Ingrese su contraseña' : null,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _cargando ? null : _ingresar,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: _cargando
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('INICIAR SESIÓN'),
                    ),
                    const SizedBox(height: 20),
                    BotonesSociales(
                      habilitado: !_cargando,
                      alElegir: _ingresarCon,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _cargando ? null : _registrarse,
                      child: const Text('¿No tiene cuenta? Regístrese'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
