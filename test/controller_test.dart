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
}
