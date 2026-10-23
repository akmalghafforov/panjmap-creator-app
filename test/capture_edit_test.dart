import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/capture_editor.dart';
import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/recent_objects.dart';
import 'package:panjmap_capture/capture/services.dart';

import 'controller_test.dart' show MemoryStore, Device;

class EditApi extends CaptureApi {
  EditApi() : super('https://example.test');
  Map<String, dynamic> place = {
    'id': 'one',
    'revision': 1,
    'house_number': '1',
  };
  Map<String, dynamic> entrance = {'id': 'gate', 'revision': 1, 'label': '2'};
  int patches = 0, reads = 0;
  List<Map<String, dynamic>> references = [];
  Map<String, dynamic>? lastCommand;
  bool loseResponse = false;
  Completer<void>? patchGate;
  Future<List<int>> Function()? image;
  @override
  Future<List<int>> thumbnail(String id) {
    reads++;
    return image!();
  }

  @override
  Future<dynamic> get(String path) async {
    if (path.startsWith('places/recent')) return [place];
    if (path.startsWith('entrances/')) return entrance;
    return place;
  }

  @override
  Future<Map<String, dynamic>> getPage(String path) async => {
    'data': references,
    'meta': {'page': 1, 'last_page': 1},
  };
  @override
  Future<Map<String, dynamic>> patchCapture(
    String id,
    Map<String, dynamic> command,
    String key,
  ) async {
    patches++;
    lastCommand = command;
    final changes = Map<String, dynamic>.from(command['place'] as Map)
      ..remove('base_revision');
    place = {...place, ...changes, 'revision': 2};
    if (command['entrance'] != null) {
      entrance = {
        ...entrance,
        'label': command['entrance']['label'],
        'revision': 2,
      };
    }
    await patchGate?.future;
    if (loseResponse) throw StateError('lost response');
    return place;
  }
}

Map<String, dynamic> row({String type = 'apartment_building'}) => {
  'id': 'one',
  'revision': 1,
  'editable': true,
  'type': type,
  'house_number': '1',
  'mahalla_name': 'Сохранённая махалля',
  'street': 'Сохранённая улица',
  'entrance': {
    'id': 'gate',
    'revision': 1,
    'label': '2',
    'editable': true,
    'latitude': 39.5,
    'longitude': 67.6,
  },
};
CaptureController controller(EditApi api, {MemoryStore? edits}) =>
    CaptureController(api, MemoryStore(), Device())
      ..editStore = edits ?? MemoryStore()
      ..account = 'owner'
      ..authenticated = true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'lost response reconciles after restart without a duplicate PATCH',
    () async {
      final api = EditApi()..loseResponse = true;
      final edits = MemoryStore();
      final c = controller(api, edits: edits);
      await c.save({'creation': 'preserved'});
      final command = {
        'place': {'base_revision': 1, 'house_number': '12'},
        'entrance': {'id': 'gate', 'base_revision': 1, 'label': '3'},
      };
      await expectLater(
        c.saveCapture(row(), command, {'house_number': '12'}),
        throwsStateError,
      );
      expect(c.pendingEdit, isNotNull);
      final restored = controller(api, edits: edits);
      await restored.initialize();
      await restored.saveCapture(row(), command, {});
      expect(api.patches, 1);
      expect(restored.pendingEdit, isNull);
      expect(await edits.read(), isNull);
      expect(c.draft, {'creation': 'preserved'});
      c.dispose();
      restored.dispose();
    },
  );
  test(
    'late save responses retain the command for the original session',
    () async {
      final api = EditApi()..patchGate = Completer<void>();
      final c = controller(api);
      final saving = c.saveCapture(row(), {
        'place': {'base_revision': 1, 'house_number': '12'},
      }, {});
      await Future<void>.delayed(Duration.zero);
      c.authenticated = false;
      c.authenticated = true;
      api.patchGate!.complete();
      await expectLater(saving, throwsStateError);
      expect(c.pendingEdit, isNotNull);
      expect(c.pendingEdit!['account'], 'owner');
      c.dispose();
    },
  );
  test(
    'thumbnail failures can be retried without requesting originals',
    () async {
      final api = EditApi()
        ..image = () async => throw StateError('unavailable');
      final c = controller(api);
      final photo = {
        'id': 'p',
        'processing_state': 'processed',
        'derivative_version': 1,
      };
      expect(await c.loadThumbnail(photo), isNull);
      api.image = () async => [1];
      expect(await c.loadThumbnail(photo), [1]);
      expect(api.reads, 2);
      c.dispose();
    },
  );
  test('conflict and wrong account preserve the pending edit', () async {
    final api = EditApi()..loseResponse = true;
    final c = controller(api);
    final command = {
      'place': {'base_revision': 1, 'house_number': '12'},
    };
    await expectLater(c.saveCapture(row(), command, {}), throwsStateError);
    api.place['revision'] = 5;
    await expectLater(c.saveCapture(row(), command, {}), throwsStateError);
    expect(c.pendingEdit, isNotNull);
    c.account = 'other';
    await expectLater(c.saveCapture(row(), command, {}), throwsStateError);
    expect(api.patches, 1);
    c.dispose();
  });
  test('thumbnails use session memory and discard stale responses', () async {
    final api = EditApi();
    final c = controller(api);
    final photo = {
      'id': 'photo',
      'processing_state': 'processed',
      'derivative_version': 1,
    };
    api.image = () async => [1, 2, 3];
    expect(await c.loadThumbnail(photo), [1, 2, 3]);
    await c.loadThumbnail(photo);
    expect(api.reads, 1);
    final delayed = Completer<List<int>>();
    api.image = () => delayed.future;
    final pending = c.loadThumbnail({...photo, 'derivative_version': 2});
    c.authenticated = false;
    c.authenticated = true;
    delayed.complete([4]);
    expect(await pending, isNull);
    expect(c.thumbnailBytes, isEmpty);
    expect(
      await c.loadThumbnail({...photo, 'processing_state': 'failed'}),
      isNull,
    );
    c.dispose();
  });
  test('unfinished creation disables only the matching object', () async {
    final c = controller(EditApi());
    await c.save({
      'place': {'id': 'one'},
    });
    expect(c.captureEditable(row()), false);
    expect(c.captureEditable({...row(), 'id': 'two'}), true);
    await c.save({...c.draft!, 'photoDone': true});
    expect(c.captureEditable(row()), true);
    c.dispose();
  });
  testWidgets(
    'cards wrap at narrow width and double text size with missing addresses',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = controller(EditApi())
        ..recentObjects = [
          row(),
          {'id': 'old', 'type': 'clinic'},
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(body: RecentObjects(controller: c)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Номер подъезда: 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Только просмотр'), 300);
      expect(find.text('Улица: Не указано'), findsOneWidget);
      expect(tester.takeException(), isNull);
      c.dispose();
    },
  );
  testWidgets(
    'editor prefills legacy data and cancels without changing creation draft',
    (tester) async {
      final c = controller(EditApi());
      await c.save({'houseNumber': 'creation draft'});
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => CaptureEditor(
                      controller: c,
                      row: row(type: 'clinic'),
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Клиника'), findsOneWidget);
      expect(find.text('Сохранённая улица'), findsOneWidget);
      final house = find.widgetWithText(TextField, '1');
      await tester.enterText(house, '99');
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.text('Несохранённые изменения будут потеряны.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Закрыть'));
      await tester.pumpAndSettle();
      expect(c.draft, {'houseNumber': 'creation draft'});
      c.dispose();
    },
  );
  testWidgets(
    'editor keyboard selection saves references and preserves GPS and draft',
    (tester) async {
      final api = EditApi()
        ..references = [
          {'id': 'new-reference', 'revision': 3, 'name': 'Новая улица'},
        ];
      final c = controller(api);
      await c.save({
        'fix': {'latitude': 1, 'longitude': 2},
        'houseNumber': 'draft',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CaptureEditor(controller: c, row: row()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextField, 'Сохранённая улица'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Новая улица'), findsOneWidget);
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(api.lastCommand!['place']['street_id'], 'new-reference');
      expect(
        api.lastCommand!['place']['address_choices']['lookup']['latitude'],
        39.5,
      );
      expect(api.lastCommand!.containsKey('entrance'), false);
      expect(c.draft!['houseNumber'], 'draft');
      expect(c.draft!['fix']['latitude'], 1);
      c.dispose();
    },
  );
  testWidgets(
    'editor requires an apartment entrance number and clears it when changing type',
    (tester) async {
      final api = EditApi();
      final c = controller(api);
      await tester.pumpWidget(
        MaterialApp(
          home: CaptureEditor(controller: c, row: row()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '2'), '');
      await tester.pump();
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(
        find.text('Введите номер подъезда (до 100 символов)'),
        findsOneWidget,
      );
      expect(api.patches, 0);
      await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Магазин').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(api.lastCommand!['place']['type'], 'shop');
      expect(api.lastCommand!['entrance']['label'], isNull);
      c.dispose();
    },
  );
  testWidgets(
    'reload confirms replacing a pending edit and loads current values',
    (tester) async {
      final api = EditApi()
        ..place = {...row(), 'revision': 2, 'house_number': 'Server value'};
      final c = controller(api);
      c.pendingEdit = {
        'id': 'one',
        'origin': api.origin,
        'account': 'owner',
        'row': row(),
        'values': {
          'type': 'apartment_building',
          'house_number': 'My edit',
          'label': '2',
          'choices': {},
        },
        'command': {
          'place': {'base_revision': 1, 'house_number': 'My edit'},
        },
        'key': 'saved-key',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: CaptureEditor(controller: c, row: row()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Загрузить текущие данные'));
      await tester.tap(find.text('Загрузить текущие данные'));
      await tester.pumpAndSettle();
      expect(
        find.text('Изменения будут заменены текущими данными с сервера.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Загрузить'));
      await tester.pumpAndSettle();
      expect(c.pendingEdit, isNull);
      expect(find.widgetWithText(TextField, 'Server value'), findsOneWidget);
      c.dispose();
    },
  );
  testWidgets('editor fits a narrow screen with doubled text and a keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = controller(EditApi());
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(2),
            viewInsets: EdgeInsets.only(bottom: 220),
          ),
          child: child!,
        ),
        home: CaptureEditor(controller: c, row: row()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('control-edit-house')),
      120,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Сохранить'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.takeException(), isNull);
    c.dispose();
  });
}
