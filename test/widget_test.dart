import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'dart:convert';

import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/services.dart';

import 'controller_test.dart' show MemoryStore, Device, mapFix;

import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/main.dart' as app;

class AddressApi extends CaptureApi {
  AddressApi() : super('https://example.test/api/v1');
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
  testWidgets('prefill, edit existing text, clear and confirm replacement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ScreenController()
      ..authenticated = true
      ..area = 'area'
      ..areas = [
        {'collection_area_id': 'area', 'name': 'Участок'},
      ];
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
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Махалля: Автоматическая'), findsOneWidget);
    await tester.tap(find.text('Ввести название').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Автоматическая'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Ручная');
    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();
    expect(find.text('Махалля: Ручная'), findsOneWidget);
    await tester.tap(find.text('Заменить: Автоматическая'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Сейчас: Ручная'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('Махалля: Ручная'), findsOneWidget);
    await tester.tap(find.text('Заменить: Автоматическая'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Заменить'));
    await tester.pumpAndSettle();
    expect(find.text('Махалля: Автоматическая'), findsOneWidget);
    expect(c.draft!['addressChoices']['mahalla']['provenance'], 'manual');
    await tester.tap(find.text('Очистить').first);
    await tester.pumpAndSettle();
    expect(find.text('Махалля: —'), findsOneWidget);
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
    expect(c.mapMessage, contains('Показан Пенджикент'));
    final name = find.widgetWithText(TextField, 'Название (необязательно)');
    await tester.ensureVisible(name);
    await tester.enterText(name, 'Сохранённое имя');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить новый объект'));
    await tester.pumpAndSettle();
    expect(find.text('Сохранённое имя'), findsOneWidget);
    final mapTop = tester.getTopLeft(find.byType(FlutterMap));
    await tester.drag(find.byType(ListView).last, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(FlutterMap)), mapTop);
    expect(c.draft!['fix']['latitude'], 1);
    c.mapPosition = mapFix();
    c.mapRevision++;
    c.redraw();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Текущее местоположение'), findsOneWidget);
    expect(
      MapCamera.of(tester.element(find.byType(TileLayer))).center.latitude,
      39.51,
    );
    expect(MapCamera.of(tester.element(find.byType(TileLayer))).zoom, 16);
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
        tester.getSize(find.byType(FlutterMap)).height,
        greaterThanOrEqualTo(100),
      );
    });
  }
  testWidgets('Keyboard shrinks the pinned map without scrolling it away', (
    tester,
  ) async {
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
    final before = tester.getSize(find.byType(FlutterMap)).height;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FlutterMap)).height, lessThan(before));
    expect(
      tester.getSize(find.byType(FlutterMap)).height,
      greaterThanOrEqualTo(100),
    );
    expect(tester.takeException(), isNull);
  });
}
