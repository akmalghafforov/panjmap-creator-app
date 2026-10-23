import 'package:flutter/material.dart';

import 'collector_map.dart';
import 'controller.dart';
import 'models.dart';
import 'capture_editor.dart';

import 'dart:typed_data';

class RecentObjects extends StatelessWidget {
  final CaptureController controller;
  const RecentObjects({super.key, required this.controller});

  String date(dynamic value) {
    final d = DateTime.tryParse('$value')?.toLocal();
    if (d == null) return '';
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(d.day)}.${pad(d.month)}.${d.year} ${pad(d.hour)}:${pad(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListView(
      key: const Key('recent-objects'),
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Недавно добавленные объекты',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              tooltip: 'Обновить объекты',
              onPressed: c.recentLoading ? null : c.refreshRecentObjects,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        MapLocationNotice(controller: c),
        if (c.recentLoading) ...[
          const LinearProgressIndicator(),
          const Text('Загрузка объектов…'),
        ],
        if (c.recentError != null) ...[
          Text(c.recentError!),
          TextButton(
            onPressed: c.refreshRecentObjects,
            child: const Text('Повторить загрузку'),
          ),
        ],
        if (!c.recentLoading &&
            c.recentError == null &&
            c.recentObjects.isEmpty)
          const Text('Вы ещё не добавили объекты.'),
        if (c.ownPendingEdit)
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CaptureEditor(
                  controller: c,
                  row: Map<String, dynamic>.from(c.pendingEdit!['row'] as Map),
                ),
              ),
            ),
            child: const Text('Продолжить сохранённое редактирование'),
          ),
        for (final row in c.recentObjects)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RecentThumbnail(
                        key: ValueKey(
                          '${c.sessionGeneration}:${c.recentRevision}:${row['entrance']?['photo']}',
                        ),
                        controller: c,
                        photo: row['entrance']?['photo'] as Map?,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${row['name'] ?? ''}'.trim().isNotEmpty
                              ? '${row['name']}'
                              : placeLabels[row['type']] ?? 'Объект',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Тип: ${placeLabels[row['type']] ?? row['type'] ?? 'Не указан'}',
                  ),
                  Text('Махалля: ${detail(row['mahalla_name'])}'),
                  Text('Улица: ${detail(row['street'])}'),
                  Text('Номер адреса: ${detail(row['house_number'])}'),
                  if (row['type'] == 'apartment_building')
                    Text(
                      'Номер подъезда: ${detail(row['entrance']?['label'])}',
                    ),
                  if (row['address_text'] != null)
                    Text('Адрес: ${detail(row['address_text'])}'),
                  Text(
                    'Добавлен: ${date(row['created_at']).isEmpty ? 'Не указано' : date(row['created_at'])}',
                  ),
                  if (row['editable'] == true && !c.captureEditable(row))
                    const Text('Отправка объекта ещё не завершена'),
                  if (row['editable'] != true) const Text('Только просмотр'),
                  if (row['editable'] == true)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: c.captureEditable(row)
                            ? () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      CaptureEditor(controller: c, row: row),
                                ),
                              )
                            : null,
                        child: const Text('Редактировать'),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String detail(dynamic value) =>
      '$value'.trim().isEmpty || value == null ? 'Не указано' : '$value';
}

class RecentThumbnail extends StatefulWidget {
  final CaptureController controller;
  final Map? photo;
  const RecentThumbnail({super.key, required this.controller, this.photo});
  @override
  State<RecentThumbnail> createState() => _RecentThumbnailState();
}

class _RecentThumbnailState extends State<RecentThumbnail> {
  late final Future<Uint8List?> bytes = widget.photo == null
      ? Future.value()
      : widget.controller.loadThumbnail(widget.photo!);
  @override
  void dispose() {
    // Image.memory also uses Flutter's decoded-image cache. Evict that copy
    // when this card leaves the tree, including when the session ends.
    bytes.then((data) {
      if (data != null) MemoryImage(data).evict();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 72,
    height: 72,
    child: FutureBuilder<Uint8List?>(
      future: bytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        Widget placeholder(String label, IconData icon) => Semantics(
          label: label,
          child: Tooltip(
            message: label,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(icon),
            ),
          ),
        );
        if (data != null) {
          return Image.memory(
            data,
            fit: BoxFit.cover,
            gaplessPlayback: false,
            errorBuilder: (_, _, _) =>
                placeholder('Фото недоступно', Icons.broken_image_outlined),
          );
        }
        if (widget.photo == null) {
          return placeholder('Нет фото', Icons.photo_outlined);
        }
        if (widget.photo!['processing_state'] == 'failed') {
          return placeholder(
            'Ошибка обработки фото',
            Icons.broken_image_outlined,
          );
        }
        if (widget.photo!['processing_state'] != 'processed' ||
            snapshot.connectionState == ConnectionState.waiting) {
          return placeholder('Фото обрабатывается', Icons.hourglass_empty);
        }
        return placeholder('Фото недоступно', Icons.broken_image_outlined);
      },
    ),
  );
}
