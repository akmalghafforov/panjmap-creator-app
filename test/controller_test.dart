import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/services.dart';

class MemoryStore implements DraftStore {
  Map<String, dynamic>? value;
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> v) async {
    if (fail) {
      throw StateError('disk full');
    }
    value = v;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class Device implements CaptureDevice {
  @override
  Future<XFile?> photo({bool recover = false}) async => null;
  @override
  Future<Position> position() async => throw TimeoutException('GPS');
  @override
  Future<bool> approximate() async => true;
}

class MapDevice extends Device {
  final gate = Completer<Position>();
  int calls = 0;
  @override
  Future<Position> position() {
    calls++;
    return gate.future;
  }
}

Position mapFix() => Position(
  latitude: 39.51,
  longitude: 67.62,
  timestamp: DateTime.now(),
  accuracy: 8,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  late MemoryStore store;
  late CaptureController c;
  setUp(() {
    store = MemoryStore();
    c = CaptureController(
      CaptureApi('https://example.test/api/v1'),
      store,
      Device(),
    );
  });
  test('Double taps perform only one operation', () async {
    final gate = Completer<void>();
    var calls = 0;
    final first = c.run(() async {
      calls++;
      await gate.future;
    });
    await c.run(() async {
      calls++;
    });
    gate.complete();
    await first;
    expect(calls, 1);
  });
  test('Camera cancellation preserves saved capture', () async {
    await c.save({'file': 'previous'});
    await c.capture();
    expect(c.draft!['file'], 'previous');
  });
  test('GPS failure preserves previous fix', () async {
    await c.save({
      'fix': {'latitude': 1},
    });
    await c.run(c.locate);
    expect(c.draft!['fix']['latitude'], 1);
    expect(c.error, isNotNull);
  });
  test('Failed atomic save preserves in-memory draft', () async {
    await c.save({'file': 'previous'});
    store.fail = true;
    await c.run(() => c.save({'file': 'new'}));
    expect(c.draft!['file'], 'previous');
  });
  test('Stale location prevents writes', () async {
    c.authenticated = true;
    c.area = 'area';
    c.type = 'shop';
    await c.save({
      'file': 'photo',
      'fix': {
        'fix_time': DateTime.now()
            .subtract(const Duration(minutes: 3))
            .toIso8601String(),
      },
    });
    await c.submit();
    expect(c.frozen, false);
    expect(c.error, contains('двух минут'));
  });
  test('Original account required for frozen draft', () async {
    c.authenticated = true;
    c.account = 'other';
    await c.save({
      'place': {'id': 'uuid'},
      'origin': c.api.origin,
      'account': 'original',
    });
    await c.submit();
    expect(c.error, contains('исходным'));
  });
  test(
    'Map requests coalesce and never alter draft or submission state',
    () async {
      final device = MapDevice();
      final controller = CaptureController(c.api, store, device)
        ..authenticated = true;
      await controller.save({
        'place': {'id': 'frozen'},
        'photoDone': true,
      });
      final draft = controller.draft;
      final first = controller.refreshMapLocation();
      final second = controller.refreshMapLocation();
      expect(device.calls, 1);
      expect(controller.busy, false);
      device.gate.complete(mapFix());
      await Future.wait([first, second]);
      expect(controller.mapPosition!.latitude, 39.51);
      expect(controller.mapLoading, false);
      expect(controller.draft, same(draft));
      expect(controller.complete, true);
      expect(controller.error, isNull);
    },
  );
  test('Expired session ignores pending map fix', () async {
    final device = MapDevice();
    final controller = CaptureController(c.api, store, device)
      ..authenticated = true;
    final request = controller.refreshMapLocation();
    controller.authenticated = false;
    controller.authenticated = true;
    device.gate.complete(mapFix());
    await request;
    expect(controller.mapPosition, isNull);
    expect(controller.mapLoading, false);
  });
  test(
    'Map failure clears pin while preserving saved GPS and errors',
    () async {
      c.authenticated = true;
      c.mapPosition = mapFix();
      c.error = 'existing';
      await c.save({
        'fix': {'latitude': 1},
      });
      await c.refreshMapLocation();
      expect(c.mapPosition, isNull);
      expect(c.mapMessage, contains('30 секунд'));
      expect(c.error, 'existing');
      expect(c.draft!['fix']['latitude'], 1);
    },
  );
}
