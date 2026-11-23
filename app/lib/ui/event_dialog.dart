import 'package:material_ui/material_ui.dart';

import '../util/utf8_truncate.dart';

/// Contenido de un evento antes de convertirlo en paquete del protocolo.
class EventDraft {
  const EventDraft({required this.categoryId, required this.note});

  final int categoryId;
  final String note;
}

/// Alta de un evento en la posición propia.
///
/// Devuelve un [EventDraft] con la nota ya recortada a 64 bytes UTF-8, o `null`
/// si el operador cancela.
class EventDialog extends StatefulWidget {
  const EventDialog({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  @override
  State<EventDialog> createState() => _EventDialogState();
}

class _EventDialogState extends State<EventDialog> {
  static const int _maxNoteBytes = 64;

  final TextEditingController _note = TextEditingController();
  int _category = 0;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(
      context,
      EventDraft(
        categoryId: _category,
        note: truncateUtf8(_note.text.trim(), _maxNoteBytes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nuevo evento'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'En ${widget.latitude.toStringAsFixed(5)}, '
            '${widget.longitude.toStringAsFixed(5)}',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            autofocus: true,
            maxLength: _maxNoteBytes,
            decoration: const InputDecoration(labelText: 'Nota breve'),
          ),
          DropdownButtonFormField<int>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Categoría'),
            items: const <DropdownMenuItem<int>>[
              DropdownMenuItem<int>(value: 0, child: Text('Genérico')),
              DropdownMenuItem<int>(value: 1, child: Text('Peligro')),
              DropdownMenuItem<int>(value: 2, child: Text('Recurso')),
              DropdownMenuItem<int>(value: 3, child: Text('Punto de reunión')),
              DropdownMenuItem<int>(value: 4, child: Text('Control')),
            ],
            onChanged: (value) =>
                setState(() => _category = value ?? _category),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _save, child: const Text('Marcar')),
      ],
    );
  }
}
