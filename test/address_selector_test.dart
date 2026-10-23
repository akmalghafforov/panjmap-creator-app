import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/address_lookup.dart';
import 'package:panjmap_capture/capture/address_selector.dart';
import 'package:panjmap_capture/capture/controller.dart';

import 'controller_test.dart' show MemoryStore, Device;
import 'retry_test.dart' show Server;

class PickerController extends CaptureController {
  PickerController() : super(Server(), MemoryStore(), Device()) {
    authenticated = true;
  }
  final requests =
      <
        ({
          String kind,
          String query,
          int page,
          Completer<Map<String, dynamic>> result,
        })
      >[];
  @override
  Future<Map<String, dynamic>> searchAddress(
    String kind,
    String query, {
    int page = 1,
  }) {
    final result = Completer<Map<String, dynamic>>();
    requests.add((kind: kind, query: query, page: page, result: result));
    return result.future;
  }

  void redraw() => notifyListeners();
}

Map<String, dynamic> response(
  String name, {
  int page = 1,
  int last = 1,
  bool legacy = false,
}) => {
  'data': [
    if (name.isNotEmpty) {'id': name, 'name': name, 'revision': 3},
  ],
  'meta': {legacy ? 'current_page' : 'page': page, 'last_page': last},
};

Future<void> mount(
  WidgetTester tester,
  PickerController c, {
  String kind = 'streets',
  Future<void> Function(Map<String, dynamic>)? onSelected,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            AddressSelector(
              controller: c,
              kind: kind,
              label: 'Название',
              onSelected:
                  onSelected ??
                  (row) => c.chooseAddress(
                    kind == 'streets' ? 'street' : 'mahalla',
                    'accepted',
                    reference: row,
                  ),
            ),
            const TextField(
              decoration: InputDecoration(labelText: 'Другое поле'),
            ),
          ],
        ),
      ),
    ),
  ),
);
Finder get searchField => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == 'Название',
);

void main() {
  testWidgets(
    'automatic load, anchored loading, debounce, stale result and empty state',
    (tester) async {
      final c = PickerController();
      await mount(tester, c);
      expect(c.requests.single.query, '');
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(searchField);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.enterText(searchField, 'Новая');
      c.requests.first.result.complete(response('Старая'));
      await tester.pump(const Duration(milliseconds: 299));
      expect(c.requests.length, 1);
      expect(find.text('Старая'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(c.requests.last.query, 'Новая');
      c.requests.last.result.complete(response('Новая'));
      await tester.pump();
      expect(find.widgetWithText(ListTile, 'Новая'), findsOneWidget);
      await tester.enterText(searchField, 'нет');
      await tester.pump(const Duration(milliseconds: 300));
      c.requests.last.result.complete(response(''));
      await tester.pump();
      expect(find.text('Ничего не найдено'), findsOneWidget);
    },
  );

  testWidgets(
    'street scrolling loads more, retries same page and accepts legacy metadata',
    (tester) async {
      final c = PickerController();
      await mount(tester, c);
      c.requests.single.result.complete({
        'data': List.generate(
          12,
          (i) => {'id': '$i', 'name': 'Улица $i', 'revision': 1},
        ),
        'meta': {'page': 1, 'last_page': 2},
      });
      await tester.pump();
      await tester.tap(searchField);
      await tester.pump();
      expect(c.requests.length, 1);
      final list = find.descendant(
        of: find.byKey(const ValueKey('dropdown-streets')),
        matching: find.byType(ListView),
      );
      await tester.drag(list, const Offset(0, -900));
      await tester.pump();
      expect(c.requests.last.page, 2);
      c.requests.last.result.completeError(StateError('offline'));
      await tester.pump();
      await tester.drag(list, const Offset(0, -200));
      await tester.pump();
      await tester.tap(find.text('Повторить'));
      expect(c.requests.last.page, 2);
      c.requests.last.result.complete(
        response('Последняя', page: 2, last: 2, legacy: true),
      );
      await tester.pump();
      expect(find.widgetWithText(ListTile, 'Последняя'), findsOneWidget);
      expect(find.text('Повторить'), findsNothing);
    },
  );

  testWidgets(
    'query is transient, focus dismissal restores label, keyboard selects reference',
    (tester) async {
      final c = PickerController();
      await c.chooseAddress(
        'street',
        'accepted',
        reference: {'id': 'old', 'name': 'Выбранная', 'revision': 1},
      );
      await mount(tester, c);
      c.requests.single.result.complete(response('Новая'));
      await tester.pump();
      await tester.enterText(searchField, 'несохранённая');
      expect(c.draft!['addressChoices']['street']['name'], 'Выбранная');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Выбранная'), findsOneWidget);
      expect(find.byKey(const ValueKey('dropdown-streets')), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      c.requests.last.result.complete(response('Другой результат'));
      await tester.pump();
      await tester.tap(searchField);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.requests.last.query, '');
      c.requests.last.result.complete(response('Новая'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(c.draft!['addressChoices']['street'], {
        'status': 'accepted',
        'provenance': 'manual',
        'id': 'Новая',
        'name': 'Новая',
        'reference_revision': 3,
        'selected_name': 'Новая',
      });
      expect(find.widgetWithText(TextField, 'Новая'), findsOneWidget);
      expect(find.byKey(const ValueKey('dropdown-streets')), findsNothing);
    },
  );

  testWidgets('initial failure retry, tap selection and outside dismissal', (
    tester,
  ) async {
    final c = PickerController();
    await mount(tester, c);
    c.requests.single.result.completeError(StateError('offline'));
    await tester.pump();
    await tester.tap(searchField);
    await tester.pump();
    await tester.tap(find.text('Повторить'));
    c.requests.last.result.complete(response('Новая'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'Новая'));
    await tester.pump();
    expect(c.draft!['addressChoices']['street']['id'], 'Новая');
    await tester.tap(searchField);
    await tester.pump();
    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    expect(find.byKey(const ValueKey('dropdown-streets')), findsNothing);
    expect(find.widgetWithText(TextField, 'Новая'), findsOneWidget);
  });

  testWidgets('disposed and previous session responses are ignored', (
    tester,
  ) async {
    final c = PickerController();
    await mount(tester, c, kind: 'mahallas');
    c.authenticated = false;
    c.authenticated = true;
    c.redraw();
    c.requests.single.result.complete(response('Старая сессия', last: 2));
    await tester.pump();
    expect(c.requests.length, 1);
    expect(find.text('Старая сессия'), findsNothing);
    final fresh = PickerController();
    await tester.pumpWidget(const SizedBox());
    await mount(tester, fresh);
    await tester.pumpWidget(const SizedBox());
    fresh.requests.single.result.complete(response('Поздняя'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('street requests stay independent from committed mahalla', () async {
    final c = PickerController();
    final lookup = AddressLookup(c, 'streets');
    addTearDown(lookup.dispose);
    c.requests.single.result.complete(response('Улица'));
    await Future<void>.delayed(Duration.zero);
    await c.chooseAddress(
      'mahalla',
      'accepted',
      reference: {'id': 'm', 'name': 'Махалля', 'revision': 4},
    );
    expect(c.requests.length, 1);
    expect(lookup.rows.single['name'], 'Улица');
  });

  test(
    'legacy free text blocks validation; accepted reference persists',
    () async {
      final store = MemoryStore();
      final c = CaptureController(Server(), store, Device());
      await c.save({
        'addressChoices': {
          'mahalla': {'status': 'corrected', 'name': 'Старая'},
        },
      });
      expect(c.validateFields(), false);
      expect(c.fieldErrors['mahalla'], 'Выберите название из списка');
      await c.chooseAddress(
        'mahalla',
        'accepted',
        reference: {'id': 'm', 'name': 'Новая', 'revision': 4},
      );
      expect(store.value!['addressChoices']['mahalla']['provenance'], 'manual');
      expect(c.addressPayload({})['mahalla_id'], 'm');
      expect(
        c.addressPayload(
          {},
        )['address_choices']['mahalla']['reference_revision'],
        4,
      );
    },
  );
}
