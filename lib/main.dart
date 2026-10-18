import 'dart:io';
import 'dart:async';

import 'capture/collector_map.dart';
import 'capture/recent_objects.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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
  final TileProvider? tileProvider;
  const CaptureScreen({super.key, required this.controller, this.tileProvider});
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final email = TextEditingController(), password = TextEditingController();
  final name = TextEditingController();
  bool formOpen = false;
  int session = -1;

  void openForm() {
    setState(() => formOpen = true);
    unawaited(c.refreshMapLocation());
  }

  void closeForm() {
    FocusScope.of(context).unfocus();
    setState(() => formOpen = false);
    unawaited(c.refreshRecentObjects());
  }

  CaptureController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    name.text = c.name;
    session = c.sessionGeneration;
    c.addListener(update);
    c.initialize();
  }

  void update() {
    if (mounted) {
      setState(() {
        if (session != c.sessionGeneration || !c.authenticated) {
          formOpen = false;
          session = c.sessionGeneration;
        }
      });
    }
  }

  @override
  void dispose() {
    c.removeListener(update);
    name.dispose();
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
    final proposed = c.reliableSuggestion(key);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label: ${choice == null
                  ? '—'
                  : choice['status'] == 'unknown'
                  ? '—'
                  : choice['name']}',
            ),
            if (choice?['provenance'] == 'automatic')
              const Text('Заполнено автоматически'),
            if (choice == null || choice['status'] == 'unknown')
              const Text('Введите название вручную или оставьте поле пустым.'),
            if (choice != null &&
                choice['provenance'] != 'automatic' &&
                proposed != null &&
                (choice['id'] != proposed['id'] ||
                    choice['name'] != proposed['name']))
              TextButton(
                onPressed: c.busy
                    ? null
                    : () => replaceAddress(key, choice, proposed),
                child: Text('Заменить: ${proposed['name']}'),
              ),
            for (final candidate in candidates)
              TextButton(
                onPressed: c.busy
                    ? null
                    : () async {
                        final reference = Map<String, dynamic>.from(
                          candidate as Map,
                        );
                        if (choice != null &&
                            choice['provenance'] != 'automatic') {
                          await confirmSelection(key, choice, reference);
                        } else {
                          await c.run(
                            () => c.chooseAddress(
                              key,
                              'accepted',
                              reference: reference,
                            ),
                          );
                        }
                      },
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
                  child: const Text('Очистить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> confirmReplacement(Map current, Map proposed) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Заменить название?'),
          content: Text(
            'Сейчас: ${current['name'] ?? '—'}\nПредлагается: ${proposed['name']}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Заменить'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> replaceAddress(
    String key,
    Map current,
    Map<String, dynamic> proposed,
  ) async {
    if (await confirmReplacement(current, proposed)) {
      await c.run(() => c.replaceAddress(key, proposed, current));
    }
  }

  Future<void> confirmSelection(
    String key,
    Map current,
    Map<String, dynamic> proposed,
  ) async {
    final originalArea = c.area;
    final originalFix = c.draft?['fix'];
    final originalSuggestions = c.suggestions;
    if (await confirmReplacement(current, proposed)) {
      if (c.suggestions != originalSuggestions ||
          c.area != originalArea ||
          c.draft?['fix'] != originalFix ||
          (c.draft?['addressChoices'] as Map?)?[key] != current) {
        return;
      }
      await c.run(() => c.chooseAddress(key, 'accepted', reference: proposed));
    }
  }

  Future<void> correctAddress(String key, String label) async {
    final field = TextEditingController(
      text:
          ((c.draft?['addressChoices'] as Map?)?[key] as Map?)?['name']
              as String? ??
          '',
    );
    final route = DialogRoute<String>(
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
              Navigator.pop(context, field.text.trim());
            },
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    final value = await Navigator.of(context).push(route);
    await route.completed;
    field.dispose();
    if (value != null) {
      await c.run(
        () => c.chooseAddress(
          key,
          value.isEmpty ? 'unknown' : 'corrected',
          name: value,
        ),
      );
    }
  }

  Future<void> searchAddress(String key, String label, String kind) async {
    final field = TextEditingController();
    List<Map<String, dynamic>> results = [];
    String? searchError;
    var sequence = 0;
    final route = DialogRoute<Map<String, dynamic>>(
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
    final reference = await Navigator.of(context).push(route);
    await route.completed;
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
    return PopScope(
      canPop: !formOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && formOpen) closeForm();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: formOpen ? BackButton(onPressed: closeForm) : null,
          title: const Text('Panjmap — сбор данных'),
          actions: c.authenticated
              ? [
                  IconButton(
                    tooltip: 'Войти повторно',
                    icon: const Icon(Icons.login),
                    onPressed: c.busy
                        ? null
                        : () => setState(() {
                            c.authenticated = false;
                            formOpen = false;
                          }),
                  ),
                ]
              : null,
        ),
        body: SafeArea(
          child: c.authenticated && !formOpen
              ? LayoutBuilder(
                  builder: (context, constraints) => Column(
                    children: [
                      SizedBox(
                        key: const Key('home-map'),
                        height: constraints.maxHeight / 2,
                        child: Stack(
                          children: [
                            CollectorMap(
                              controller: c,
                              tileProvider: widget.tileProvider,
                            ),
                            Positioned(
                              bottom: 16,
                              right: 16,
                              child: FloatingActionButton(
                                tooltip: 'Добавить новый объект',
                                onPressed: openForm,
                                child: const Icon(Icons.add),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: RecentObjects(controller: c)),
                    ],
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => Column(
                    children: [
                      if (c.authenticated)
                        SizedBox(
                          height: (constraints.maxHeight * .30).clamp(
                            100.0,
                            220.0,
                          ),
                          child: CollectorMap(
                            controller: c,
                            tileProvider: widget.tileProvider,
                          ),
                        ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            if (!c.authenticated ||
                                c.error?.contains('Сессия') == true) ...[
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
                                decoration: const InputDecoration(
                                  labelText: 'Пароль',
                                ),
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
                                    : () => setState(
                                        () => c.authenticated = false,
                                      ),
                                child: const Text('Войти повторно'),
                              ),
                              if (!c.frozen) ...[
                                DropdownButtonFormField<String>(
                                  initialValue: c.area,
                                  decoration: const InputDecoration(
                                    labelText: 'Участок сбора',
                                  ),
                                  items: c.areas
                                      .map(
                                        (a) => DropdownMenuItem(
                                          value:
                                              a['collection_area_id'] as String,
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
                                  decoration: const InputDecoration(
                                    labelText: 'Тип объекта',
                                  ),
                                  items: types
                                      .map(
                                        (t) => DropdownMenuItem(
                                          value: '$t',
                                          child: Text(labels[t] ?? '$t'),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: c.busy
                                      ? null
                                      : (v) => setState(() => c.type = v),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  decoration: const InputDecoration(
                                    labelText: 'Название (необязательно)',
                                  ),
                                  controller: name,
                                  onChanged: (v) => c.name = v,
                                  maxLength: 255,
                                  enabled: !c.busy,
                                ),
                                button(
                                  'Сфотографировать вход',
                                  () => c.run(() => c.capture()),
                                ),
                                button(
                                  'Получить свежие координаты',
                                  () => c.run(c.locate),
                                ),
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
                                  ((c.draft?['fix']?['accuracy_m'] as num?) ??
                                          0) >
                                      30)
                                const Text(
                                  'Внимание: приблизительное местоположение или точность хуже 30 м.',
                                ),
                              if (!c.frozen && c.draft?['fix'] != null) ...[
                                if (c.suggestionError != null)
                                  Text(c.suggestionError!),
                                if ((c.suggestions?['ambiguity_reasons']
                                            as List? ??
                                        [])
                                    .isNotEmpty)
                                  const Text(
                                    'Адрес неоднозначен: рядом граница, пересечение махаллей или несколько улиц. Проверьте выбор.',
                                  ),
                                addressReview('mahalla', 'Махалля', 'mahallas'),
                                addressReview('street', 'Улица', 'streets'),
                                button(
                                  'Повторить подсказки',
                                  () => c.run(c.suggest),
                                ),
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
                                button(
                                  'Проверить обработку',
                                  () => c.run(c.poll),
                                ),
                                button('Начать следующую запись', c.next),
                              ],
                            ],
                            if (c.busy)
                              LinearProgressIndicator(
                                value: c.progress > 0 && c.progress < 1
                                    ? c.progress
                                    : null,
                              ),
                            if (c.authenticated)
                              MapLocationNotice(controller: c),
                            Text(c.status),
                            if (c.error != null) ...[
                              Text(
                                c.error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
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
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
