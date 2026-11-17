import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/usuario.dart';
import '../services/api_service.dart';
import '../services/sesion.dart';
import '../utils/validadores.dart';

/// Crear (usuario == null) o editar un usuario (solo ADMIN).
/// Al editar se envía la versión leída: si otro administrador lo cambió
/// antes, la API responde 409 y se ofrece cargar los datos actuales.
class UsuarioFormPage extends StatefulWidget {
  final Usuario? usuario;
  const UsuarioFormPage({super.key, this.usuario});

  @override
  State<UsuarioFormPage> createState() => _UsuarioFormPageState();
}

class _UsuarioFormPageState extends State<UsuarioFormPage> {
  final _form = GlobalKey<FormState>();
  final _usuario = TextEditingController();
  final _nombre = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String _rol = 'CLIENTE';
  bool _estado = true;
  bool _desbloquear = false;
  int _version = 0;
  bool _bloqueado = false;
  bool _verClave = false;
  bool _guardando = false;
  String? _mensaje;
  Map<String, String> _erroresServidor = {};

  bool get _esEdicion => widget.usuario != null;
  bool get _esSocial => widget.usuario?.esSocial ?? false;
  bool get _esYoMismo => widget.usuario?.id == Sesion.actual?.id;

  @override
  void initState() {
    super.initState();
    if (widget.usuario != null) _cargar(widget.usuario!);
  }

  void _cargar(Usuario u) {
    _usuario.text = u.usuario;
    _nombre.text = u.nombreCompleto;
    _email.text = u.email ?? '';
    _password.clear();
    _rol = u.rol;
    _estado = u.estado;
    _version = u.version;
    _bloqueado = u.bloqueado;
    _desbloquear = false;
  }

  @override
  void dispose() {
    for (final c in [_usuario, _nombre, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  String? Function(String?) _v(String campo, String? Function(String?) local) =>
      (valor) => local(valor) ?? _erroresServidor[campo];

  Map<String, dynamic> _cuerpo() {
    final email = _email.text.trim();
    return {
      if (!_esEdicion) 'usuario': _usuario.text.trim(),
      'nombre_completo': Validadores.limpiar(_nombre.text),
      'email': email.isEmpty ? null : email,
      'rol': _rol,
      'estado': _estado,
      if (_password.text.isNotEmpty) 'password': _password.text,
      if (_esEdicion) 'version': _version, // <- concurrencia optimista
      if (_esEdicion && _desbloquear) 'desbloquear': true,
    };
  }

  Future<void> _guardar() async {
    setState(() {
      _erroresServidor = {};
      _mensaje = null;
    });
    if (!_form.currentState!.validate()) return;
    setState(() => _guardando = true);
    try {
      final r = _esEdicion
          ? await ApiService.actualizarUsuario(widget.usuario!.id, _cuerpo())
          : await ApiService.crearUsuario(_cuerpo());
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(r.mensaje)));
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.esConcurrencia && e.usuario != null) {
        await _dialogoConcurrencia(e);
      } else {
        setState(() {
          _erroresServidor = e.errores;
          _mensaje = e.mensaje;
        });
        _form.currentState!.validate();
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _dialogoConcurrencia(ApiException e) async {
    final actual = e.usuario!;
    final recargar = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.sync_problem, color: Colors.orange, size: 40),
        title: const Text('Otro administrador modificó este usuario'),
        content: Text('${e.mensaje}\n\nValores actuales:\n'
            '• Nombre: ${actual.nombreCompleto}\n'
            '• Rol: ${actual.rolLegible}\n'
            '• Estado: ${actual.estado ? 'Activo' : 'Desactivado'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cargar datos actuales')),
        ],
      ),
    );
    if (recargar == true && mounted) {
      setState(() {
        _cargar(actual);
        _mensaje = 'Se cargaron los datos actuales. Revise y vuelva a guardar.';
      });
    }
  }

  Widget _campo(String campo, String etiqueta, TextEditingController c,
      {required String? Function(String?) validar,
      required List<TextInputFormatter> fmt,
      bool habilitado = true,
      bool clave = false,
      String? ayuda,
      TextInputType teclado = TextInputType.text,
      TextCapitalization cap = TextCapitalization.none}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        enabled: habilitado,
        obscureText: clave && !_verClave,
        keyboardType: teclado,
        textCapitalization: cap,
        inputFormatters: fmt,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        decoration: InputDecoration(
          labelText: etiqueta,
          helperText: ayuda,
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
      appBar: AppBar(title: Text(_esEdicion ? 'Editar usuario' : 'Nuevo usuario')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (_mensaje != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(padding: const EdgeInsets.all(12), child: Text(_mensaje!)),
                ),
              _campo('usuario', 'Usuario', _usuario,
                  habilitado: !_esEdicion,
                  ayuda: _esEdicion ? 'El nombre de usuario no se puede cambiar' : null,
                  fmt: Validadores.usuarioFmt,
                  validar: (v) => _esEdicion ? null : Validadores.usuario(v)),
              _campo('nombre_completo', 'Nombre completo', _nombre,
                  cap: TextCapitalization.words,
                  fmt: [...Validadores.soloLetrasFmt, LengthLimitingTextInputFormatter(100)],
                  validar: (v) => Validadores.soloLetras(v, 'Nombre', 3, 100)),
              _campo('email', 'Correo (opcional)', _email,
                  teclado: TextInputType.emailAddress,
                  fmt: Validadores.emailFmt,
                  validar: (v) => Validadores.email(v)),
              if (!_esSocial)
                _campo('password', _esEdicion ? 'Nueva contraseña (opcional)' : 'Contraseña', _password,
                    clave: true,
                    ayuda: _esEdicion
                        ? 'Déjela vacía para no cambiarla. Si la cambia, se cierran sus sesiones.'
                        : '8 a 50, con letras y números',
                    fmt: Validadores.passwordFmt,
                    validar: (v) => Validadores.password(v, obligatorio: !_esEdicion))
              else
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('Cuenta de Google/Facebook: no usa contraseña.'),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: _rol,
                  key: ValueKey('rol$_rol'),
                  decoration: InputDecoration(
                    labelText: 'Rol',
                    border: const OutlineInputBorder(),
                    helperText: _esYoMismo ? 'No puede quitarse su propio rol de administrador' : null,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'ADMIN', child: Text('ADMIN · CRUD completo y usuarios')),
                    DropdownMenuItem(
                        value: 'FARMACEUTICO', child: Text('FARMACEUTICO · inventario y stock')),
                    DropdownMenuItem(value: 'CLIENTE', child: Text('CLIENTE · catálogo y detalle')),
                  ],
                  onChanged: _esYoMismo ? null : (v) => setState(() => _rol = v!),
                ),
              ),
              SwitchListTile(
                title: const Text('Cuenta activa'),
                subtitle: const Text('Si se desactiva, se cierran sus sesiones'),
                value: _estado,
                onChanged: _esYoMismo ? null : (v) => setState(() => _estado = v),
              ),
              if (_esEdicion && _bloqueado)
                CheckboxListTile(
                  title: const Text('Desbloquear (tiene intentos fallidos)'),
                  value: _desbloquear,
                  onChanged: (v) => setState(() => _desbloquear = v ?? false),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _guardando ? null : _guardar,
                icon: _guardando
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                label: Text(_esEdicion ? 'Guardar cambios' : 'Crear usuario'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
