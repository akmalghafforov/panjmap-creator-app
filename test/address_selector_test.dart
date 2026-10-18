import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/address_selector.dart';
import 'package:panjmap_capture/capture/controller.dart';

import 'controller_test.dart' show MemoryStore, Device;
import 'retry_test.dart' show Server;

class PickerController extends CaptureController {
  PickerController() : super(Server(), MemoryStore(), Device()) {
    authenticated = true;
  }
  final requests =
      <({String query, int page, Completer<Map<String, dynamic>> result})>[];
  @override
  Future<Map<String, dynamic>> searchAddress(
    String kind,
    String query, {
    int page = 1,
  }) {
    final result = Completer<Map<String, dynamic>>();
    requests.add((query: query, page: page, result: result));
    return result.future;
  }
}

Map<String, dynamic> response(String name, {int page = 1, int last = 1}) => {
  'data': [
    if (name.isNotEmpty) {'id': name, 'name': name, 'revision': 3},
  ],
  'meta': {'current_page': page, 'last_page': last},
};
void main() {
  testWidgets(
    'initial load, debounce, stale response, pages, failure and retry',
    (tester) async {
      final c = PickerController();
      await tester.pumpWidget(
        MaterialApp(
          home: AddressSelector(controller: c, kind: 'streets', label: 'Улица'),
        ),
      );
      expect(c.requests.single.query, '');
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Новая');
      c.requests.first.result.complete(response('Старая'));
      await tester.pump(const Duration(milliseconds: 299));
      expect(c.requests.length, 1);
      expect(find.text('Старая'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(c.requests.last.query, 'Новая');
      c.requests.last.result.complete(response('Новая', last: 2));
      await tester.pump();
      await tester.tap(find.text('Загрузить ещё'));
      expect(c.requests.last.page, 2);
      c.requests.last.result.completeError(StateError('offline'));
      await tester.pump();
      await tester.tap(find.text('Повторить'));
      expect(c.requests.last.page, 2);
      c.requests.last.result.complete(response('Вторая', page: 2, last: 2));
      await tester.pump();
      expect(find.widgetWithText(ListTile, 'Новая'), findsOneWidget);
      expect(find.text('Вторая'), findsOneWidget);
      expect(find.text('Загрузить ещё'), findsNothing);
      await tester.enterText(find.byType(TextField), 'нет');
      await tester.pump(const Duration(milliseconds: 300));
      c.requests.last.result.complete(response(''));
      await tester.pump();
      expect(find.text('Ничего не найдено'), findsOneWidget);
    },
  );
  testWidgets('disposed and previous session responses are ignored', (
    tester,
  ) async {
    final c = PickerController();
    await tester.pumpWidget(
      MaterialApp(
        home: AddressSelector(
          controller: c,
          kind: 'mahallas',
          label: 'Махалля',
        ),
      ),
    );
    c.sessionGeneration++;
    c.requests.single.result.complete(response('Старая сессия'));
    await tester.pump();
    expect(find.text('Старая сессия'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Поздняя');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    c.requests.last.result.complete(response('Поздняя'));
    await tester.pump();
    expect(tester.takeException(), isNull);
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
