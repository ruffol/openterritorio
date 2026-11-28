import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_state.dart';
import '../data/backend_client.dart';
import '../data/noticias.dart';

/// Hoja con las noticias guardadas en el servidor: sirve para revisar los
/// sucesos de días pasados sin depender de lo que esté en el tablero en vivo.
Future<void> mostrarNoticias(
  BuildContext context, {
  required BackendClient client,
  required AppState state,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _PanelNoticias(client: client, state: state),
  );
}

class _PanelNoticias extends StatefulWidget {
  const _PanelNoticias({required this.client, required this.state});

  final BackendClient client;
  final AppState state;

  @override
  State<_PanelNoticias> createState() => _PanelNoticiasState();
}

class _PanelNoticiasState extends State<_PanelNoticias> {
  static const List<int> _dias = <int>[1, 7, 30, 90];

  int _diasElegidos = 7;
  bool _cargando = true;
  String? _error;
  List<Noticia> _notas = const <Noticia>[];

  @override
  void initState() {
    super.initState();
    _diasElegidos = widget.state.diasNoticias;
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final crudas = await widget.client.fetchNews(dias: _diasElegidos);
      final lista = <Noticia>[
        for (final item in crudas)
          if (item is Map<String, dynamic>) Noticia.fromJson(item),
      ];
      if (!mounted) return;
      setState(() {
        _notas = lista;
        _cargando = false;
      });
      widget.state.diasNoticias = _diasElegidos;
      widget.state.aplicarNoticias(lista);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _cargando = false;
      });
    }
  }

  String _hora(DateTime? cuando) {
    if (cuando == null) return 'sin fecha';
    final hoy = DateTime.now();
    final mismoDia = cuando.year == hoy.year && cuando.month == hoy.month && cuando.day == hoy.day;
    final hhmm = '${cuando.hour.toString().padLeft(2, '0')}:${cuando.minute.toString().padLeft(2, '0')}';
    if (mismoDia) return 'hoy $hhmm';
    return '${cuando.day.toString().padLeft(2, '0')}/${cuando.month.toString().padLeft(2, '0')} $hhmm';
  }

  @override
  Widget build(BuildContext context) {
    final alto = MediaQuery.of(context).size.height * 0.82;
    return SizedBox(
      height: alto,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                const Icon(Icons.article_outlined, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Noticias guardadas',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Recargar',
                  onPressed: _cargando ? null : _cargar,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: <Widget>[
                for (final dias in _dias)
                  ChoiceChip(
                    label: Text(dias == 1 ? 'hoy' : '$dias días'),
                    selected: _diasElegidos == dias,
                    onSelected: (elegido) {
                      if (!elegido) return;
                      setState(() => _diasElegidos = dias);
                      _cargar();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No se pudieron leer las noticias:\n$_error',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_notas.isEmpty) {
      return const Center(child: Text('Sin noticias guardadas en este periodo'));
    }
    return ListView.separated(
      itemCount: _notas.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final nota = _notas[i];
        return ListTile(
          leading: _miniatura(nota),
          title: Text(
            nota.etiqueta.isEmpty ? nota.tipo : nota.etiqueta,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${_hora(nota.cuando)} · ${nota.municipio.isEmpty ? 'Colima' : nota.municipio}'
            '${nota.aproximada ? ' · ubicación aproximada' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _abrir(context, nota),
        );
      },
    );
  }

  Widget _miniatura(Noticia nota) {
    if (nota.imagen.isEmpty) {
      return CircleAvatar(
        radius: 18,
        child: Text(
          nota.tipo.isEmpty ? '?' : nota.tipo.characters.first.toUpperCase(),
          style: const TextStyle(fontSize: 13),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        nota.imagen,
        width: 56,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox(
          width: 56,
          height: 40,
          child: Icon(Icons.broken_image_outlined, size: 18),
        ),
      ),
    );
  }

  void _abrir(BuildContext context, Noticia nota) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(nota.etiqueta.isEmpty ? 'Noticia' : nota.etiqueta),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(_hora(nota.cuando), style: Theme.of(context).textTheme.labelSmall),
              if (nota.aproximada) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'Ubicación aproximada: la nota solo precisa el municipio.',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
              if (nota.imagen.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    nota.imagen,
                    height: 150,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              SelectableText(
                nota.texto.isEmpty ? 'Sin cita guardada.' : nota.texto,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
              if (nota.fuentes.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  nota.fuentes.length > 1
                      ? 'Publicada por ${nota.fuentes.length} fuentes'
                      : 'Fuente',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                for (final fuente in nota.fuentes)
                  Text('· $fuente', style: const TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          if (nota.url.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                final uri = Uri.tryParse(nota.url);
                if (uri == null) return;
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Ver nota completa'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}
