import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../data/ota_service.dart';

/// Descarga e instala una actualización mostrando el progreso.
///
/// Se cierra con `ok`, `permission` o `error:<mensaje>` (o `null` si el usuario
/// cierra un error).
class OtaUpdateDialog extends StatefulWidget {
  const OtaUpdateDialog({
    super.key,
    required this.service,
    required this.update,
  });

  final OtaService service;
  final OtaUpdate update;

  @override
  State<OtaUpdateDialog> createState() => _OtaUpdateDialogState();
}

class _OtaUpdateDialogState extends State<OtaUpdateDialog> {
  double _progress = 0;
  bool _installing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final File apk = await widget.service.download(
        widget.update,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          });
        },
      );
      if (!mounted) return;
      setState(() => _installing = true);
      final result = await widget.service.install(apk);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return AlertDialog(
        title: const Text('No se pudo actualizar'),
        content: Text(error),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('error:$error'),
            child: const Text('Cerrar'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text('Actualizando a v${widget.update.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: _progress > 0 ? _progress : null,
          ),
          const SizedBox(height: 12),
          Text(
            _installing
                ? 'Abriendo el instalador del sistema…'
                : '${(_progress * 100).toStringAsFixed(0)} % '
                    'de ${_formatBytes(widget.update.sizeBytes)}',
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return 'tamaño desconocido';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}
