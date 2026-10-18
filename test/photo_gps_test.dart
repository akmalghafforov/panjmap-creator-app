import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/services.dart';

import 'controller_test.dart' show MemoryStore, Device, mapFix;

class PhotoDevice extends Device {
  XFile? image;
  int photos = 0, positions = 0;
  Future<Position> Function() gps = () async => mapFix();
  @override
  Future<XFile?> photo({bool recover = false}) async {
    photos++;
    return image;
  }

  @override
  Future<Position> position() {
    positions++;
    return gps();
  }
}

class PhotoApi extends CaptureApi {
  PhotoApi() : super('https://example.test/api/v1');
  int suggestions = 0;
  @override
  Future<dynamic> get(String path) async {
    suggestions++;
    return <String, dynamic>{};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late PhotoDevice device;
  late MemoryStore store;
  late PhotoApi api;
  late CaptureController c;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('photo-gps');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dir.path,
        );
    final file = File('${dir.path}/photo.png');
    await file.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
    device = PhotoDevice()..image = XFile(file.path);
    store = MemoryStore();
    api = PhotoApi();
    c = CaptureController(api, store, device)..authenticated = true;
    await c.save({
      'file': 'previous',
      'fix': {'latitude': 1},
      'approximate': true,
      'addressChoices': {
        'mahalla': {'provenance': 'manual', 'name': 'Manual'},
        'street': {'provenance': 'automatic', 'name': 'Old'},
      },
    });
    c.suggestions = {'old': true};
  });
  tearDown(() async {
    c.dispose();
    await dir.delete(recursive: true);
  });

  test('Photo automatically persists GPS and refreshes suggestions', () async {
    await c.run(() => c.capture());
    expect(device.positions, 1);
    expect(c.draft!['file'], isNot('previous'));
    expect(store.value!['fix']['latitude'], mapFix().latitude);
    expect(store.value!['fix']['accuracy_m'], 8);
    expect(store.value!['fix']['fix_time'], isNotNull);
    expect(c.mapPosition, isNotNull);
    expect(api.suggestions, 1);
    expect(c.draft!['addressChoices'], {
      'mahalla': {'provenance': 'manual', 'name': 'Manual'},
    });
  });

  test(
    'Failed GPS retains photo without old fix; retry needs no photo',
    () async {
      device.gps = () async => throw TimeoutException('GPS');
      await c.run(() => c.capture());
      final path = c.draft!['file'];
      expect(path, isNot('previous'));
      expect(await File(path as String).exists(), true);
      expect(store.value!['fix'], isNull);
      expect(c.draft!['approximate'], isNull);
      expect(c.suggestions, isNull);
      expect(c.error, contains('Получить свежие координаты'));
      expect(c.validateFields(), false);
      expect(c.fieldErrors, contains('gps'));
      device.gps = () async => mapFix();
      await c.run(c.locate);
      expect(c.draft!['file'], path);
      expect(c.draft!['fix'], isNotNull);
      expect(device.photos, 1);
    },
  );

  for (final failure in ['cancel', 'invalid', 'storage']) {
    test('$failure preserves previous draft', () async {
      final previous = c.draft;
      if (failure == 'cancel') device.image = null;
      if (failure == 'invalid') {
        final file = File('${dir.path}/bad');
        await file.writeAsString('invalid');
        device.image = XFile(file.path);
      }
      if (failure == 'storage') store.fail = true;
      await c.run(() => c.capture());
      expect(c.draft, same(previous));
      expect(device.positions, 0);
      expect(c.suggestions, {'old': true});
    });
  }

  test(
    'Recovery clears GPS and automatic choices without requesting GPS',
    () async {
      c.authenticated = false;
      await c.capture(recover: true);
      expect(c.draft!['file'], isNot('previous'));
      expect(c.draft!['fix'], isNull);
      expect(device.positions, 0);
      expect(c.status, contains('Получить свежие координаты'));
    },
  );

  test('Frozen draft never opens camera', () async {
    await c.save({
      ...c.draft!,
      'place': {'id': 'frozen'},
    });
    await c.capture();
    expect(device.photos, 0);
  });

  test(
    'Double taps share busy operation and late GPS ignores new session',
    () async {
      final gate = Completer<Position>();
      device.gps = () => gate.future;
      final first = c.run(() => c.capture());
      while (device.positions == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(c.status, 'Получение координат…');
      await c.run(() => c.capture());
      expect(device.photos, 1);
      c.authenticated = false;
      c.authenticated = true;
      gate.complete(mapFix());
      await first;
      expect(c.draft!['fix'], isNull);
      expect(c.mapPosition, isNull);
      expect(api.suggestions, 0);
    },
  );
}
