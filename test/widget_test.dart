import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'dart:convert';

import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/services.dart';
import 'package:panjmap_capture/capture/models.dart';

import 'controller_test.dart' show MemoryStore, Device;

import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/main.dart' as app;

class AddressApi extends CaptureApi {
  AddressApi() : super('https://example.test/api/v1');
  @override
  Future<Map<String, dynamic>> getPage(String path) async => {
    'data': <Map<String, dynamic>>[],
    'meta': {'page': 1, 'last_page': 1},
  };
  @override
  Future<dynamic> get(String path) async => {
    'recommended_mahalla_id': 'm',
    'mahallas': [
      {'id': 'm', 'name': 'Автоматическая', 'revision': 1, 'contains': true},
    ],
  };
}

class ScreenController extends CaptureController {
  ScreenController() : super(AddressApi(), MemoryStore(), Device());
  @override
  Future<void> capture({bool recover = false}) async {
    photoRevision++;
    notifyListeners();
  }

  void redraw() => notifyListeners();
  @override
  Future<void> initialize() async {}
}

class TestTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
        ),
      );
}

void main() {
  testWidgets('exact field order, five options and entrance visibility', (
    tester,
  ) async {
    final c = ScreenController()..authenticated = true;
    await c.editField('type', 'apartment_building');
    await tester.pumpWidget(
      MaterialApp(
        home: app.CaptureScreen(controller: c, tileProvider: TestTiles()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить новый объект'));
    await tester.pumpAndSettle();
    final type = tester
        .widgetList<DropdownButton<String>>(find.byType(DropdownButton<String>))
        .last;
    expect(type.items!.map((item) => item.value).toList(), [
      'private_house',
      'apartment_building',
      'shop',
      'pharmacy',
      'other',
    ]);
    Finder field(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label,
    );
    final order = [
      field('Махалля'),
      field('Улица'),
      find.byType(DropdownButtonFormField<String>).last,
      field('Номер подъезда'),
      field('Номер адреса'),
      find.text('GPS-координаты'),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        tester.getTopLeft(order[i]).dy,
        greaterThan(tester.getTopLeft(order[i - 1]).dy),
      );
    }
    expect(capturePlaceTypes.values.toList(), [
      'Дом',
      'Этаж',
      'Магазин',
      'Аптека',
      'Другое',
    ]);
    expect(find.text('Название (необязательно)'), findsNothing);
    for (final type in capturePlaceTypes.keys) {
      await c.editField('type', type);
      await tester.pumpAndSettle();
      expect(
        field('Номер подъезда'),
        type == 'apartment_building' ? findsOneWidget : findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'equal outlined controls at text scale $scale with external errors and counters',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = ScreenController()..authenticated = true;
        await c.editField('type', 'apartment_building');
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: app.CaptureScreen(
                controller: c,
                tileProvider: TestTiles(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Добавить новый объект'));
        await tester.pumpAndSettle();
        const names = [
          'mahalla',
          'street',
          'type',
          'entranceNumber',
          'houseNumber',
        ];
        final controls = [
          for (final name in names) find.byKey(ValueKey('control-$name')),
        ];
        final initial = [
          for (final control in controls) tester.getSize(control),
        ];
        expect(initial.toSet().length, 1);
        expect(initial.first.width, 280);
        expect(initial.first.height, scale == 1 ? 56 : 80);
        for (final control in controls) {
          final decoration = find.descendant(
            of: control,
            matching: find.byType(InputDecorator),
          );
          expect(tester.getSize(decoration), initial.first);
          expect(
            tester.widget<InputDecorator>(decoration).decoration.border,
            isA<OutlineInputBorder>(),
          );
        }
        c.validateFields();
        await tester.pump();
        expect([
          for (final control in controls) tester.getSize(control),
        ], initial);
        expect(find.text('Обязательное поле'), findsWidgets);
        expect(find.text('0/100'), findsOneWidget);
        expect(find.text('0/80'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('save is disabled explicitly while GPS is pending', (
    tester,
  ) async {
    final c = ScreenController()..authenticated = true;
    await tester.pumpWidget(
      MaterialApp(
        home: app.CaptureScreen(controller: c, tileProvider: TestTiles()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить новый объект'));
    await tester.pumpAndSettle();
    Finder save() => find.widgetWithText(FilledButton, 'Сохранить');
    expect(tester.widget<FilledButton>(save()).onPressed, isNotNull);
    c.gpsPending = true;
    c.redraw();
    await tester.pump();
    expect(tester.widget<FilledButton>(save()).onPressed, isNull);
    c.gpsPending = false;
    c.redraw();
    await tester.pump();
    expect(tester.widget<FilledButton>(save()).onPressed, isNotNull);
  });
  for (final size in [const Size(360, 800), const Size(800, 360)]) {
    testWidgets('Home equal split and history scroll at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ScreenController()..authenticated = true;
      c.mapMessage = 'Местоположение недоступно';
      c.recentObjects = List.generate(
        20,
        (i) => {
          'type': 'shop',
          'name': i == 0 ? '' : 'Объект $i',
          'created_at': '2026-10-18T10:00:00Z',
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: app.CaptureScreen(controller: c, tileProvider: TestTiles()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final map = tester.getRect(find.byKey(const Key('home-map')));
      final list = tester.getRect(find.byKey(const Key('recent-objects')));
      expect(map.height, list.height);
      final button = tester.getRect(find.byType(FloatingActionButton));
      expect(map.right - button.right, 16);
      expect(map.bottom - button.bottom, 16);
      final attribution = tester.getRect(
        find.text('© OpenStreetMap contributors'),
      );
      expect(attribution.overlaps(button), false);
      await tester.scrollUntilVisible(
        find.text('Объект 19'),
        250,
        scrollable: find.descendant(
          of: find.byKey(const Key('recent-objects')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(tester.getRect(find.byKey(const Key('home-map'))), map);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Missing API root gives actionable configuration guidance', (
    tester,
  ) async {
    app.main();
    await tester.pump();
    expect(find.textContaining('API_BASE_URL'), findsOneWidget);
  });
  testWidgets('prefill, editable search and confirmed replacement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ScreenController()..authenticated = true;
    await c.save({
      'fix': {'latitude': 39.5, 'longitude': 67.6, 'accuracy_m': 8},
    });
    await c.suggest();
    await tester.pumpWidget(
      MaterialApp(
        home: app.CaptureScreen(controller: c, tileProvider: TestTiles()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить новый объект'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Заполнено автоматически'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.widgetWithText(TextField, 'Автоматическая'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Автоматическая'))
          .readOnly,
      false,
    );
    await c.chooseAddress(
      'mahalla',
      'accepted',
      reference: {'id': 'manual', 'name': 'Ручная', 'revision': 2},
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Заменить: Автоматическая'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Сейчас: Ручная'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Ручная'), findsOneWidget);
    await tester.tap(find.text('Заменить: Автоматическая'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Заменить'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Автоматическая'), findsOneWidget);
    expect(c.draft!['addressChoices']['mahalla']['provenance'], 'manual');
    expect(find.text('Очистить'), findsNothing);
    expect(find.text('Повторить подсказки'), findsNothing);
    expect(find.text('Сохранить'), findsOneWidget);
  });
  testWidgets('Map landing, pin, Back and reopening preserve form values', (
    tester,
  ) async {
    final c = ScreenController()..authenticated = true;
    c.config = {
      'enums': {
        'place_type': ['shop'],
      },
    };
    await c.save({
      'fix': {'latitude': 1, 'longitude': 2},
    });
    await tester.pumpWidget(
      MaterialApp(
        home: app.CaptureScreen(controller: c, tileProvider: TestTiles()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      MapCamera.of(tester.element(find.byType(TileLayer))).center.latitude,
      39.495,
    );
    await tester.tap(find.byTooltip('Добавить новый объект'));
    await tester.pumpAndSettle();
    expect(find.byType(FlutterMap), findsNothing);
    expect(find.text('Сфотографировать вход'), findsNothing);
    expect(find.text('Получить свежие координаты'), findsNothing);
    final name = find.widgetWithText(TextField, 'Номер адреса');
    await tester.scrollUntilVisible(
      name,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(name, 'Сохранённое имя');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить новый объект'));
    await tester.pumpAndSettle();
    expect(find.text('Сохранённое имя'), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
    expect(c.draft!['fix']['latitude'], 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Добавить новый объект'), findsOneWidget);
  });

  for (final size in [
    const Size(320, 640),
    const Size(800, 360),
    const Size(360, 400),
  ]) {
    testWidgets('Form fits $size with enlarged text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ScreenController()..authenticated = true;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(2)),
            child: app.CaptureScreen(controller: c, tileProvider: TestTiles()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Добавить новый объект'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('form-photo'))).height,
        greaterThanOrEqualTo(100),
      );
    });
  }
  testWidgets('Keyboard shrinks the pinned photo preview', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final c = ScreenController()..authenticated = true;
    await tester.pumpWidget(
      MaterialApp(
        home: app.CaptureScreen(controller: c, tileProvider: TestTiles()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить новый объект'));
    await tester.pumpAndSettle();
    final before = tester.getSize(find.byKey(const Key('form-photo'))).height;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('form-photo'))).height,
      lessThan(before),
    );
    expect(
      tester.getSize(find.byKey(const Key('form-photo'))).height,
      greaterThanOrEqualTo(100),
    );
    expect(tester.takeException(), isNull);
  });
}
