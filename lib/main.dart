import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'capture/controller.dart';
import 'capture/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('API_BASE_URL');
  final uri = Uri.tryParse(root);
  final valid =
      uri != null &&
      uri.hasAuthority &&
      (uri.scheme == 'https' || (kDebugMode && uri.scheme == 'http')) &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty;
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        ),
      ),
      home: valid
          ? CaptureScreen(
              controller: CaptureController(
                CaptureApi(root.replaceFirst(RegExp(r'/$'), '')),
                FileDraftStore(),
                AndroidCapture(),
              ),
            )
          : const Scaffold(
              body: Center(
                child: Text(
                  'Задайте полный API_BASE_URL через --dart-define. Для release требуется HTTPS.',
                ),
              ),
            ),
    ),
  );
}

class CaptureScreen extends StatefulWidget {
  final CaptureController controller;
  const CaptureScreen({super.key, required this.controller});
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final email = TextEditingController(), password = TextEditingController();
  CaptureController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(update);
    c.initialize();
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    c.removeListener(update);
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Widget button(String label, Future<void> Function() action) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: FilledButton(onPressed: c.busy ? null : action, child: Text(label)),
  );
  Widget addressReview(String key, String label, String kind) {
    final choice = (c.draft?['addressChoices'] as Map?)?[key] as Map?;
    final candidates = c.suggestions?[kind] as List? ?? [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label: ${choice == null
                  ? 'не подтверждено'
                  : choice['status'] == 'unknown'
                  ? 'Неизвестно'
                  : choice['name']}',
            ),
            for (final candidate in candidates)
              TextButton(
                onPressed: c.busy
                    ? null
                    : () => c.run(
                        () => c.chooseAddress(
                          key,
                          'accepted',
                          reference: Map<String, dynamic>.from(
                            candidate as Map,
                          ),
                        ),
                      ),
                child: Text(
                  'Принять: ${candidate['name']}${candidate['distance_m'] == null ? '' : ' · ${(candidate['distance_m'] as num).round()} м'}',
                ),
              ),
            Wrap(
              children: [
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () => searchAddress(key, label, kind),
                  child: const Text('Найти другой'),
                ),
                TextButton(
                  onPressed: c.busy ? null : () => correctAddress(key, label),
                  child: const Text('Ввести название'),
                ),
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () => c.run(() => c.chooseAddress(key, 'unknown')),
                  child: const Text('Неизвестно'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> correctAddress(String key, String label) async {
    final field = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: field,
          maxLength: 255,
          decoration: const InputDecoration(labelText: 'Исправленное название'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () {
              if (field.text.trim().isNotEmpty) {
                Navigator.pop(context, field.text.trim());
              }
            },
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    field.dispose();
    if (value != null) {
      await c.run(() => c.chooseAddress(key, 'corrected', name: value));
    }
  }

  Future<void> searchAddress(String key, String label, String kind) async {
    final field = TextEditingController();
    List<Map<String, dynamic>> results = [];
    String? searchError;
    var sequence = 0;
    final reference = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Найти: $label'),
          content: SizedBox(
            width: 350,
            height: 350,
            child: Column(
              children: [
                TextField(
                  controller: field,
                  decoration: const InputDecoration(labelText: 'Название'),
                  onSubmitted: (_) async {
                    final current = ++sequence;
                    try {
                      final found = await c.searchAddress(kind, field.text);
                      if (!context.mounted || current != sequence) return;
                      update(() {
                        results = found;
                        searchError = null;
                      });
                    } catch (_) {
                      if (context.mounted && current == sequence) {
                        update(
                          () => searchError = 'Поиск недоступен. Повторите.',
                        );
                      }
                    }
                  },
                ),
                const Text('Введите название и нажмите поиск на клавиатуре.'),
                if (searchError != null) Text(searchError!),
                Expanded(
                  child: ListView(
                    children: results
                        .map(
                          (r) => ListTile(
                            title: Text(r['name'] as String),
                            onTap: () => Navigator.pop(context, r),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
          ],
        ),
      ),
    );
    field.dispose();
    if (reference != null) {
      await c.run(() => c.chooseAddress(key, 'accepted', reference: reference));
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = (c.config['enums'] as Map?)?['place_type'] as List? ?? [];
    const labels = {
      'private_house': 'Частный дом',
      'apartment_building': 'Многоквартирный дом',
      'residential_compound': 'Жилой комплекс',
      'shop': 'Магазин',
      'building': 'Здание',
      'other': 'Другое',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Panjmap — сбор данных')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (!c.authenticated || c.error?.contains('Сессия') == true) ...[
              TextField(
                controller: email,
                decoration: const InputDecoration(
                  labelText: 'Электронная почта',
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                decoration: const InputDecoration(labelText: 'Пароль'),
                obscureText: true,
              ),
              button('Войти', () async {
                await c.login(email.text.trim(), password.text);
                password.clear();
              }),
            ] else ...[
              TextButton(
                onPressed: c.busy
                    ? null
                    : () => setState(() => c.authenticated = false),
                child: const Text('Войти повторно'),
              ),
              if (!c.frozen) ...[
                DropdownButtonFormField<String>(
                  initialValue: c.area,
                  decoration: const InputDecoration(labelText: 'Участок сбора'),
                  items: c.areas
                      .map(
                        (a) => DropdownMenuItem(
                          value: a['collection_area_id'] as String,
                          child: Text('${a['name']}'),
                        ),
                      )
                      .toList(),
                  onChanged: c.busy
                      ? null
                      : (v) => c.run(() => c.changeArea(v)),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: c.type,
                  decoration: const InputDecoration(labelText: 'Тип объекта'),
                  items: types
                      .map(
                        (t) => DropdownMenuItem(
                          value: '$t',
                          child: Text(labels[t] ?? '$t'),
                        ),
                      )
                      .toList(),
                  onChanged: c.busy ? null : (v) => setState(() => c.type = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Название (необязательно)',
                  ),
                  onChanged: (v) => c.name = v,
                  maxLength: 255,
                  enabled: !c.busy,
                ),
                button('Сфотографировать вход', () => c.run(() => c.capture())),
                button('Получить свежие координаты', () => c.run(c.locate)),
              ],
              if (c.draft?['file'] != null)
                Image.file(
                  File(c.draft!['file'] as String),
                  height: 240,
                  errorBuilder: (_, e, s) => const Text(
                    'Файл фото недоступен. Обратитесь к администратору.',
                  ),
                ),
              if (c.draft?['fix'] != null)
                SelectableText(
                  'Широта: ${c.draft!['fix']['latitude']}\nДолгота: ${c.draft!['fix']['longitude']}\nТочность: ${c.draft!['fix']['accuracy_m']} м\nВремя UTC: ${c.draft!['fix']['fix_time']}',
                ),
              if (c.draft?['approximate'] == true ||
                  ((c.draft?['fix']?['accuracy_m'] as num?) ?? 0) > 30)
                const Text(
                  'Внимание: приблизительное местоположение или точность хуже 30 м.',
                ),
              if (!c.frozen && c.draft?['fix'] != null) ...[
                if (c.suggestionError != null) Text(c.suggestionError!),
                if ((c.suggestions?['ambiguity_reasons'] as List? ?? [])
                    .isNotEmpty)
                  const Text(
                    'Адрес неоднозначен: рядом граница, пересечение махаллей или несколько улиц. Проверьте выбор.',
                  ),
                addressReview('mahalla', 'Махалля', 'mahallas'),
                addressReview('street', 'Улица', 'streets'),
                button('Повторить подсказки', () => c.run(c.suggest)),
              ],
              if (c.frozen)
                SelectableText(
                  'Объект: ${c.draft!['place']['id']}\nВход: ${c.draft!['entrance']['id']}\nФото: ${c.draft!['photoId']}',
                ),
              if (!c.complete)
                button(
                  c.frozen
                      ? 'Повторить / продолжить отправку'
                      : 'Проверено — отправить',
                  c.submit,
                ),
              if (c.complete) ...[
                button('Проверить обработку', () => c.run(c.poll)),
                button('Начать следующую запись', c.next),
              ],
            ],
            if (c.busy)
              LinearProgressIndicator(
                value: c.progress > 0 && c.progress < 1 ? c.progress : null,
              ),
            Text(c.status),
            if (c.error != null) ...[
              Text(
                c.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: Geolocator.openAppSettings,
                child: const Text('Настройки приложения'),
              ),
              TextButton(
                onPressed: Geolocator.openLocationSettings,
                child: const Text('Настройки геолокации'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
