import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/services.dart';

import 'controller_test.dart' show MemoryStore, Device;

class GeographyServer extends CaptureApi {
  GeographyServer() : super('https://example.test/api/v1');
  final pending = <Completer<dynamic>>[];
  bool fail = false;
  @override
  Future<dynamic> get(String path) {
    if (fail) throw StateError('offline');
    final next = Completer<dynamic>();
    pending.add(next);
    return next.future;
  }
}

class FreshDevice extends Device {
  @override
  Future<Position> position() async => Position(
    latitude: 39.5,
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
}

void main() {
  final fix = {'latitude': 39.495, 'longitude': 67.61, 'accuracy_m': 10};
  late GeographyServer server;
  late MemoryStore store;
  late CaptureController c;
  setUp(() async {
    server = GeographyServer();
    store = MemoryStore();
    c = CaptureController(server, store, Device())..area = 'area';
    await c.save({'fix': fix});
  });
  test('acceptance, correction and unknown serialize snapshots', () async {
    await c.chooseAddress(
      'mahalla',
      'accepted',
      reference: {'id': 'm', 'name': 'Махалля', 'revision': 2},
    );
    await c.chooseAddress('street', 'corrected', name: 'Новая улица');
    final payload = c.addressPayload(fix);
    expect(payload['mahalla_id'], 'm');
    expect(payload['street'], 'Новая улица');
    expect(payload['address_choices']['mahalla']['reference_revision'], 2);
    final restored = CaptureController(server, store, Device())
      ..draft = store.value
      ..area = 'area';
    expect(restored.addressPayload(fix), payload);
    await c.chooseAddress('street', 'unknown');
    expect(c.addressPayload(fix)['street'], null);
    expect(c.addressPayload(fix)['address_choices']['street'], {
      'status': 'unknown',
    });
  });
  test('confirmation and collection area are required', () async {
    expect(() => c.addressPayload(fix), throwsStateError);
    await c.chooseAddress('mahalla', 'unknown');
    await c.chooseAddress('street', 'unknown');
    c.area = 'another';
    expect(() => c.addressPayload(fix), throwsStateError);
  });
  test(
    'late suggestion response cannot replace newer point suggestions',
    () async {
      final old = c.suggest();
      await c.save({
        'fix': {...fix, 'latitude': 39.5},
      });
      final current = c.suggest();
      server.pending[1].complete({'recommended_mahalla_id': 'new'});
      await current;
      server.pending[0].complete({'recommended_mahalla_id': 'old'});
      await old;
      expect(c.suggestions!['recommended_mahalla_id'], 'new');
    },
  );
  test('suggestion failure permits manual and unknown choices', () async {
    server.fail = true;
    await c.suggest();
    expect(c.suggestionError, isNotNull);
    await c.chooseAddress('mahalla', 'corrected', name: 'Ручной адрес');
    await c.chooseAddress('street', 'unknown');
    expect(c.addressPayload(fix)['mahalla_name'], 'Ручной адрес');
  });
  test(
    'fresh GPS clears confirmations and uses the entrance coordinate',
    () async {
      final fresh = CaptureController(server, store, FreshDevice())
        ..area = 'area';
      await fresh.save({'fix': fix});
      await fresh.chooseAddress('mahalla', 'unknown');
      await fresh.chooseAddress('street', 'unknown');
      server.fail = true;
      await fresh.locate();
      expect(fresh.draft!['addressChoices'], isNull);
      expect(fresh.draft!['fix']['latitude'], 39.5);
      expect(fresh.draft!['fix']['measured_latitude'], 39.5);
      expect(fresh.suggestionError, isNotNull);
    },
  );
  test('frozen older draft cannot acquire address metadata', () async {
    await c.save({
      'place': {'id': 'p'},
      'fix': fix,
    });
    await c.chooseAddress('mahalla', 'unknown');
    await c.suggest();
    expect(c.draft!['addressChoices'], isNull);
    expect(server.pending, isEmpty);
  });
  test('area change clears confirmations and ignores old response', () async {
    await c.chooseAddress('mahalla', 'unknown');
    final old = c.suggest();
    final changed = c.changeArea('another');
    await Future<void>.delayed(Duration.zero);
    server.pending.last.complete({'recommended_mahalla_id': 'new'});
    await changed;
    server.pending.first.complete({'recommended_mahalla_id': 'old'});
    await old;
    expect(c.draft!['addressChoices'], isNull);
    expect(c.suggestions!['recommended_mahalla_id'], 'new');
  });
}
