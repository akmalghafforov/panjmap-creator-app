import 'package:flutter/material.dart';

import 'address_selector.dart';
import 'controller.dart';
import 'form_control.dart';
import 'models.dart';

class CaptureEditor extends StatefulWidget {
  final CaptureController controller;
  final Map<String, dynamic> row;
  const CaptureEditor({super.key, required this.controller, required this.row});

  @override
  State<CaptureEditor> createState() => _CaptureEditorState();
}

class _CaptureEditorState extends State<CaptureEditor> {
  late Map<String, dynamic> row;
  late String type;
  late final String? editorAccount = c.account;
  bool get active => c.authenticated && c.account == editorAccount;
  final house = TextEditingController(), entrance = TextEditingController();
  final choices = <String, Map<String, dynamic>>{};
  final errors = <String, String>{};
  String? error;
  bool dirty = false, leaving = false, reloading = false;
  CaptureController get c => widget.controller;
  bool get pending => c.ownPendingEdit && c.pendingEdit!['id'] == row['id'];
  Map get savedEntrance => row['entrance'] as Map? ?? {};

  @override
  void initState() {
    super.initState();
    row = Map<String, dynamic>.from(widget.row);
    if (pending) row = Map<String, dynamic>.from(c.pendingEdit!['row'] as Map);
    fill(pending ? c.pendingEdit!['values'] as Map : null);
    c.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void fill(Map? values) {
    type = (values?['type'] ?? row['type']) as String;
    house.text = '${values?['house_number'] ?? row['house_number'] ?? ''}';
    entrance.text = '${values?['label'] ?? savedEntrance['label'] ?? ''}';
    choices.clear();
    if (values?['choices'] is Map) {
      for (final e in (values!['choices'] as Map).entries) {
        choices[e.key as String] = Map<String, dynamic>.from(e.value as Map);
      }
    }
    dirty = values != null;
  }

  Future<bool> confirmDiscard({bool forReload = false}) async {
    if (c.captureSaving || reloading) return false;
    if (!dirty && !pending) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              forReload
                  ? 'Загрузить текущие данные?'
                  : 'Закрыть редактирование?',
            ),
            content: Text(
              forReload
                  ? 'Изменения будут заменены текущими данными с сервера.'
                  : pending
                  ? 'Команда сохранения останется для повторной отправки.'
                  : 'Несохранённые изменения будут потеряны.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(forReload ? 'Отмена' : 'Продолжить'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(forReload ? 'Загрузить' : 'Закрыть'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Map<String, dynamic>? command() {
    errors.clear();
    final place = <String, dynamic>{'base_revision': row['revision']};
    if (type != row['type']) place['type'] = type;
    if (house.text != '${row['house_number'] ?? ''}') {
      if (house.text.trim().isEmpty || house.text.trim().length > 80) {
        errors['house'] = 'Введите номер адреса (до 80 символов)';
      }
      place['house_number'] = house.text.trim();
    }
    if (choices.isNotEmpty) {
      final metadata = Map<String, dynamic>.from(
        row['address_choices'] as Map? ?? {},
      );
      metadata['lookup'] = {
        'latitude': savedEntrance['latitude'],
        'longitude': savedEntrance['longitude'],
        'accuracy_m': savedEntrance['accuracy_m'] ?? 0,
      };
      for (final key in ['mahalla', 'street']) {
        final selected = choices[key];
        final nameKey = key == 'street' ? 'street' : 'mahalla_name';
        place['${key}_id'] = selected?['id'] ?? row['${key}_id'];
        place[nameKey] = selected?['name'] ?? row[nameKey];
        if (selected != null) {
          metadata[key] = {
            'status': 'accepted',
            'reference_revision': selected['revision'],
            'selected_name': selected['name'],
          };
        } else {
          metadata[key] ??= {
            'status': row[nameKey] == null ? 'unknown' : 'corrected',
          };
        }
      }
      place['address_choices'] = metadata;
      if (savedEntrance['latitude'] == null ||
          savedEntrance['longitude'] == null) {
        errors['address'] = 'Нет сохранённых координат для проверки адреса.';
      }
    }
    if (type == 'apartment_building' &&
        (entrance.text.trim().isEmpty || entrance.text.trim().length > 100)) {
      errors['entrance'] = 'Введите номер подъезда (до 100 символов)';
    }
    final label =
        type != 'apartment_building' && row['type'] == 'apartment_building'
        ? null
        : entrance.text.trim();
    final changeEntrance =
        label != (savedEntrance['label'] ?? '') &&
        (type == 'apartment_building' || row['type'] == 'apartment_building');
    if (changeEntrance && savedEntrance['editable'] != true) {
      errors['entrance'] = 'Подъезд недоступен для редактирования.';
    }
    if (errors.isNotEmpty) {
      setState(() {});
      return null;
    }
    return {
      'place': place,
      if (changeEntrance)
        'entrance': {
          'id': savedEntrance['id'],
          'base_revision': savedEntrance['revision'],
          'label': label,
        },
    };
  }

  Future<void> save() async {
    if (!active || c.captureSaving || reloading) return;
    final body = pending
        ? Map<String, dynamic>.from(c.pendingEdit!['command'] as Map)
        : command();
    if (body == null) return;
    setState(() => error = null);
    try {
      await c.saveCapture(row, body, {
        'type': type,
        'house_number': house.text,
        'label': entrance.text,
        'choices': choices,
      });
      if (!mounted) return;
      setState(() {
        dirty = false;
        leaving = true;
      });
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => error = e is StateError ? e.message : '$e');
      }
    }
  }

  Future<void> reload() async {
    if (!active || c.captureSaving || reloading) return;
    if (!await confirmDiscard(forReload: true) || !mounted) return;
    setState(() => reloading = true);
    try {
      final session = c.sessionGeneration;
      await c.refreshRecentObjects();
      if (!active || session != c.sessionGeneration) return;
      var current = c.recentObjects
          .where((r) => r['id'] == row['id'])
          .firstOrNull;
      if (c.recentError != null) {
        throw StateError('Не удалось загрузить текущие данные.');
      }
      // A persisted command may outlive the recent-list window.
      if (current == null) {
        current = Map<String, dynamic>.from(
          await c.api.get('places/${row['id']}') as Map,
        );
        current['editable'] =
            row['editable'] == true &&
            current['lifecycle'] == 'active' &&
            current['verification_status'] != 'confirmed';
        if (!active || session != c.sessionGeneration) return;
        if (savedEntrance['id'] != null) {
          final latest = Map<String, dynamic>.from(
            await c.api.get('entrances/${savedEntrance['id']}') as Map,
          );
          latest['editable'] =
              savedEntrance['editable'] == true &&
              latest['lifecycle'] == 'active' &&
              latest['verification_status'] != 'confirmed';
          current['entrance'] = latest;
        }
      }
      if (!active || session != c.sessionGeneration) return;
      if (pending) await c.discardCaptureEdit();
      if (!mounted) return;
      final refreshed = Map<String, dynamic>.from(current);
      setState(() {
        row = refreshed;
        fill(null);
        dirty = false;
        error = null;
        errors.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = e is StateError ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => reloading = false);
    }
  }

  @override
  void dispose() {
    c.removeListener(changed);
    house.dispose();
    entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        active &&
        c.captureEditable(row) &&
        !pending &&
        !c.captureSaving &&
        !reloading;
    return PopScope(
      canPop: leaving || (!dirty && !pending && !c.captureSaving && !reloading),
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop && await confirmDiscard() && mounted) {
          setState(() => leaving = true);
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Редактировать объект')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!active || !c.captureEditable(row))
              const Text(
                'Только просмотр. Войдите в исходную учётную запись для продолжения.',
              ),
            IgnorePointer(
              ignoring: !enabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final key in ['mahalla', 'street'])
                    AddressSelector(
                      controller: c,
                      enabled: enabled,
                      kind: key == 'mahalla' ? 'mahallas' : 'streets',
                      label: key == 'mahalla' ? 'Махалля' : 'Улица',
                      selectedName:
                          '${choices[key]?['name'] ?? row[key == 'street' ? 'street' : 'mahalla_name'] ?? ''}',
                      savedFix: savedEntrance,
                      onSelected: (value) async {
                        setState(() {
                          choices[key] = value;
                          dirty = true;
                        });
                      },
                    ),
                  FormControl(
                    name: 'edit-type',
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(type),
                      initialValue: type,
                      isExpanded: true,
                      decoration: formDecoration('Тип здания'),
                      items: [
                        if (!capturePlaceTypes.containsKey(type))
                          DropdownMenuItem(
                            value: type,
                            child: Text(placeLabels[type] ?? type),
                          ),
                        for (final e in capturePlaceTypes.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: enabled
                          ? (value) {
                              setState(() {
                                type = value!;
                                dirty = true;
                                if (type != 'apartment_building') {
                                  entrance.clear();
                                }
                              });
                            }
                          : null,
                    ),
                  ),
                  if (type == 'apartment_building')
                    FormControl(
                      name: 'edit-entrance',
                      error: errors['entrance'],
                      child: TextField(
                        controller: entrance,
                        enabled: enabled && savedEntrance['editable'] == true,
                        decoration: formDecoration('Номер подъезда'),
                        onChanged: (_) => setState(() => dirty = true),
                      ),
                    ),
                  FormControl(
                    name: 'edit-house',
                    error: errors['house'],
                    child: TextField(
                      controller: house,
                      enabled: enabled,
                      decoration: formDecoration('Номер адреса'),
                      onChanged: (_) => setState(() => dirty = true),
                    ),
                  ),
                ],
              ),
            ),
            if (errors['address'] != null) Text(errors['address']!),
            if (errors['entrance'] != null && type != 'apartment_building')
              Text(errors['entrance']!),
            if (error != null) Text(error!),
            if (pending)
              const Text(
                'Команда сохранена. Повторная отправка проверит версии и результат предыдущего запроса.',
              ),
            if (c.captureSaving || reloading) const LinearProgressIndicator(),
            FilledButton(
              onPressed:
                  active &&
                      c.captureEditable(row) &&
                      !c.captureSaving &&
                      !reloading &&
                      (dirty || pending)
                  ? save
                  : null,
              child: Text(pending ? 'Повторить сохранение' : 'Сохранить'),
            ),
            TextButton(
              onPressed: !active || c.captureSaving || reloading
                  ? null
                  : reload,
              child: const Text('Загрузить текущие данные'),
            ),
          ],
        ),
      ),
    );
  }
}
