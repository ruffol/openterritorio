import 'package:material_ui/material_ui.dart';

import '../data/connection_settings.dart';

/// Pide URL, token e ID de dispositivo.
///
/// Devuelve una [ConnectionSettings] nueva, o `null` si el operador cancela.
class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({
    super.key,
    required this.initial,
    this.firstTime = false,
  });

  final ConnectionSettings initial;
  final bool firstTime;

  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  late final TextEditingController _url = TextEditingController(
    text: widget.initial.baseUrl,
  );
  late final TextEditingController _token = TextEditingController(
    text: widget.initial.token,
  );
  late final TextEditingController _sender = TextEditingController(
    text: '${widget.initial.senderId}',
  );

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _sender.dispose();
    super.dispose();
  }

  void _save() {
    final url = _url.text.trim();
    final senderId =
        int.tryParse(_sender.text.trim()) ?? widget.initial.senderId;
    Navigator.pop(
      context,
      ConnectionSettings(
        baseUrl: url.isEmpty ? ConnectionSettings.fallbackUrl : url,
        token: _token.text.trim(),
        senderId: senderId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Conexión'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Servidor',
                hintText: 'http://192.168.100.3:3000',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _token,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Token'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sender,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'ID de dispositivo'),
            ),
            if (widget.firstTime)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Introduce la URL y el token del backend.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _save, child: const Text('Guardar')),
      ],
    );
  }
}
