import 'dart:io';
import 'dart:async';

import 'capture/collector_map.dart';
import 'capture/address_selector.dart';
import 'capture/form_control.dart';
import 'capture/recent_objects.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';

import 'capture/controller.dart';
import 'capture/services.dart';
import 'capture/models.dart';

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

class _CaptureScreenState extends State<CaptureScreen>
    with WidgetsBindingObserver {
  final email = TextEditingController(), password = TextEditingController();
  final fields = {
    for (final key in ['houseNumber', 'entranceNumber'])
      key: TextEditingController(),
  };
  final anchors = {
    for (final key in [
      'mahalla',
      'street',
      'type',
      'entranceNumber',
      'houseNumber',
      'photo',
      'gps',
    ])
      key: GlobalKey(),
  };

  Widget input(String key, String label, int limit, {bool numeric = false}) =>
      FormControl(
        key: anchors[key],
        name: key,
        error: c.fieldErrors[key],
        counter: '${fields[key]!.text.characters.length}/$limit',
        child: TextField(
          controller: fields[key],
          enabled: !c.busy,
          maxLength: limit,
          buildCounter: (
            _, {
            required currentLength,
            required isFocused,
            maxLength,
          }) => null,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          decoration: formDecoration(label),
          onChanged: (v) {
            final work = c.editField(key, v);
            unawaited(
              work.catchError((Object e) {
                c.error = c.message(e);
                update();
              }),
            );
          },
        ),
      );

  Future<void> submit() async {
    if (!c.frozen && !c.validateFields()) {
      final key = anchors.keys.firstWhere(c.fieldErrors.containsKey);
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      final target = anchors[key]!.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 250),
        );
      }
      return;
    }
    await c.submit();
  }

  bool formOpen = false;
  int session = -1;
  int photoRevision = 0;

  Future<void> openForm() async {
    if (c.busy) return;
    if (c.frozen) {
      setState(() => formOpen = true);
      return;
    }
    final revision = c.photoRevision;
    await c.run(() => c.capture());
    if (mounted && c.authenticated && c.photoRevision != revision) {
      setState(() => formOpen = true);
    }
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
    syncFields();
    session = c.sessionGeneration;
    WidgetsBinding.instance.addObserver(this);
    c.addListener(update);
    c.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) c.checkExpiry();
  }

  void syncFields() {
    for (final key in fields.keys) {
      final value = c.draft?[key] as String? ?? '';
      if (fields[key]!.text != value) {
        fields[key]!.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      }
    }
  }

  void update() {
    syncFields();
    if (mounted) {
      setState(() {
        if (session != c.sessionGeneration || !c.authenticated) {
          formOpen = false;
          session = c.sessionGeneration;
        }
        if (c.authenticated && c.photoRevision != photoRevision) {
          photoRevision = c.photoRevision;
          formOpen = true;
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(update);
    for (final field in fields.values) {
      field.dispose();
    }
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Widget button(
    String label,
    Future<void> Function() action, {
    bool submission = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: FilledButton(
      onPressed: c.busy || c.optionsLoading || (c.gpsPending && submission)
          ? null
          : action,
      child: Text(label),
    ),
  );
  Widget addressReview(String key, String label, String kind) {
    final choice = (c.draft?['addressChoices'] as Map?)?[key] as Map?;
    final candidates = c.suggestions?[kind] as List? ?? [];
    final proposed = c.reliableSuggestion(key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AddressSelector(
          key: anchors[key],
          controller: c,
          kind: kind,
          label: label,
          onSelected: (reference) => selectAddress(key, reference),
        ),
        if (choice?['provenance'] == 'automatic')
          const Text('Заполнено автоматически'),
        if (choice == null || choice['status'] == 'unknown')
          const Text('Обязательное поле. Выберите название из списка.'),
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
                : () => selectAddress(
                    key,
                    Map<String, dynamic>.from(candidate as Map),
                  ),
            child: Text(
              'Принять: ${candidate['name']}${candidate['distance_m'] == null ? '' : ' · ${(candidate['distance_m'] as num).round()} м'}',
            ),
          ),
      ],
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
    final session = c.sessionGeneration;
    final originalFix = c.draft?['fix'];
    final originalSuggestions = c.suggestions;
    if (await confirmReplacement(current, proposed)) {
      if (!mounted ||
          !c.authenticated ||
          session != c.sessionGeneration ||
          c.suggestions != originalSuggestions ||
          c.draft?['fix'] != originalFix ||
          (c.draft?['addressChoices'] as Map?)?[key] != current) {
        return;
      }
      await c.run(() => c.chooseAddress(key, 'accepted', reference: proposed));
    }
  }

  Future<void> selectAddress(String key, Map<String, dynamic> reference) async {
    if (!mounted || !c.authenticated || c.frozen) return;
    final current = (c.draft?['addressChoices'] as Map?)?[key] as Map?;
    if (current != null && current['provenance'] != 'automatic') {
      await confirmSelection(key, current, reference);
    } else {
      await c.run(() => c.chooseAddress(key, 'accepted', reference: reference));
    }
  }

  @override
  Widget build(BuildContext context) {
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
                            unawaited(c.endSession());
                            formOpen = false;
                          }),
                  ),
                ]
              : null,
        ),
        body: SafeArea(
          child: c.authenticated && !c.collectionAvailable
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Вход выполнен: администратор. Сбор полевых данных недоступен для этой роли.',
                        ),
                        button('Сменить роль', c.endSession),
                      ],
                    ),
                  ),
                )
              : c.authenticated && !formOpen
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
                      if (c.status.isNotEmpty || c.error != null)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight / 4,
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                if (c.status.isNotEmpty) Text(c.status),
                                if (c.error != null) Text(c.error!),
                                if (c.error != null ||
                                    c.status == 'Съёмка отменена') ...[
                                  TextButton(
                                    onPressed: openForm,
                                    child: const Text('Повторить съёмку'),
                                  ),
                                  TextButton(
                                    onPressed: Geolocator.openAppSettings,
                                    child: const Text('Настройки приложения'),
                                  ),
                                ],
                              ],
                            ),
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
                          key: const Key('form-photo'),
                          height: (constraints.maxHeight * .30).clamp(
                            100.0,
                            220.0,
                          ),
                          child: c.draft?['file'] == null
                              ? const SizedBox.shrink()
                              : Image.file(
                                  File(c.draft!['file'] as String),
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, e, stack) =>
                                      const Text('Файл фото недоступен.'),
                                ),
                        ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (!c.authenticated ||
                                    c.error?.contains('Сессия') == true) ...[
                                  if (c.optionsLoading)
                                    const LinearProgressIndicator(),
                                  if (c.developmentRoleLoginEnabled) ...[
                                    if (c.roles.isEmpty) ...[
                                      const Text(
                                        'Учётные записи разработки недоступны. Запустите seeder на сервере.',
                                      ),
                                      button(
                                        'Повторить проверку',
                                        c.loadAuthOptions,
                                      ),
                                    ] else ...[
                                      DropdownButtonFormField<String>(
                                        key: ValueKey(c.selectedRole),
                                        initialValue: c.selectedRole,
                                        decoration: const InputDecoration(
                                          labelText: 'Роль',
                                        ),
                                        items: c.roles
                                            .map(
                                              (r) => DropdownMenuItem(
                                                value: r['role'] as String,
                                                child: Text(
                                                  r['label'] as String,
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: c.busy || c.optionsLoading
                                            ? null
                                            : (value) => setState(
                                                () => c.selectedRole = value,
                                              ),
                                      ),
                                      FilledButton(
                                        onPressed: c.busy || c.optionsLoading
                                            ? null
                                            : c.loginRole,
                                        child: const Text('Войти без пароля'),
                                      ),
                                    ],
                                  ] else ...[
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
                                      await c.login(
                                        email.text.trim(),
                                        password.text,
                                      );
                                      password.clear();
                                    }),
                                  ],
                                  if (c.optionsError != null) ...[
                                    Text(c.optionsError!),
                                    button(
                                      'Повторить проверку',
                                      c.loadAuthOptions,
                                    ),
                                  ],
                                ] else ...[
                                  if (!c.frozen) ...[
                                    addressReview(
                                      'mahalla',
                                      'Махалля',
                                      'mahallas',
                                    ),
                                    addressReview('street', 'Улица', 'streets'),
                                    FormControl(
                                      key: anchors['type'],
                                      name: 'type',
                                      error: c.fieldErrors['type'],
                                      child: DropdownButtonFormField<String>(
                                        key: ValueKey(c.type),
                                        isExpanded: true,
                                        itemHeight: null,
                                        initialValue:
                                            capturePlaceTypes.containsKey(
                                              c.type,
                                            )
                                            ? c.type
                                            : null,
                                        decoration: formDecoration(
                                          'Тип здания',
                                        ),
                                        items: capturePlaceTypes.entries
                                            .map(
                                              (entry) => DropdownMenuItem(
                                                value: entry.key,
                                                child: Text(
                                                  entry.value,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: c.busy
                                            ? null
                                            : (value) => c.run(
                                                () =>
                                                    c.editField('type', value!),
                                              ),
                                      ),
                                    ),
                                    if (c.type == 'apartment_building')
                                      input(
                                        'entranceNumber',
                                        'Номер подъезда',
                                        100,
                                        numeric: true,
                                      ),
                                    input('houseNumber', 'Номер адреса', 80),
                                  ],
                                  Text('GPS-координаты', key: anchors['gps']),
                                  if (c.fieldErrors['gps'] != null)
                                    Text(c.fieldErrors['gps']!),
                                  if (c.draft?['fix'] == null)
                                    const SelectableText('Широта: \nДолгота: '),
                                  if (c.gpsPending)
                                    const LinearProgressIndicator(),
                                  if (!c.frozen && c.gpsError != null) ...[
                                    Text(c.gpsError!),
                                    button('Повторить GPS', c.locate),
                                    TextButton(
                                      onPressed: Geolocator.openAppSettings,
                                      child: const Text('Настройки приложения'),
                                    ),
                                    TextButton(
                                      onPressed:
                                          Geolocator.openLocationSettings,
                                      child: const Text('Настройки геолокации'),
                                    ),
                                  ],
                                  if (c.draft?['fix'] != null)
                                    SelectableText(
                                      'Широта: ${c.draft!['fix']['latitude']}\nДолгота: ${c.draft!['fix']['longitude']}\nТочность: ${c.draft!['fix']['accuracy_m']} м\nВремя UTC: ${c.draft!['fix']['fix_time']}',
                                    ),
                                  if (c.draft?['approximate'] == true ||
                                      ((c.draft?['fix']?['accuracy_m']
                                                  as num?) ??
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
                                  ],
                                  if (c.frozen)
                                    SelectableText(
                                      'Объект: ${c.draft!['place']['id']}\nВход: ${c.draft!['entrance']['id']}\nФото: ${c.draft!['photoId']}',
                                    ),
                                  if (!c.complete)
                                    button(
                                      c.frozen
                                          ? 'Повторить / продолжить отправку'
                                          : 'Сохранить',
                                      submit,
                                      submission: true,
                                    ),
                                  if (c.complete) ...[
                                    button(
                                      'Проверить обработку',
                                      () => c.run(c.poll),
                                    ),
                                    button('Начать следующую запись', () async {
                                      await c.next();
                                      if (mounted && c.draft == null) {
                                        closeForm();
                                        await openForm();
                                      }
                                    }),
                                  ],
                                ],
                                if (c.busy)
                                  LinearProgressIndicator(
                                    value: c.progress > 0 && c.progress < 1
                                        ? c.progress
                                        : null,
                                  ),

                                Text(c.status),
                                if (c.error != null) ...[
                                  Text(
                                    c.error!,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
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
