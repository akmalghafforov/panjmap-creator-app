import 'package:flutter/material.dart';

import 'collector_map.dart';
import 'controller.dart';

const placeLabels = {
  'private_house': 'Частный дом',
  'apartment_building': 'Многоквартирный дом',
  'residential_compound': 'Жилой комплекс',
  'shop': 'Магазин',
  'building': 'Здание',
  'other': 'Другое',
};

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
        for (final row in c.recentObjects)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${row['name'] ?? ''}'.trim().isNotEmpty
                  ? '${row['name']}'
                  : placeLabels[row['type']] ?? 'Объект',
            ),
            subtitle: Text(
              [
                if ('${row['address_text'] ?? ''}'.trim().isNotEmpty)
                  '${row['address_text']}',
                date(row['created_at']),
              ].where((s) => s.isNotEmpty).join('\n'),
            ),
          ),
      ],
    );
  }
}
