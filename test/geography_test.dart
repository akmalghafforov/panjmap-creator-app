import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

class RestoreServer extends CaptureApi {
  RestoreServer() : super('https://example.test/api/v1');
  int lookups = 0;
  final requests = <String>[];
  @override
  Future<Map<String, dynamic>> post(
    String path,
    dynamic body, {
    String? key,
    progress,
  }) async {
    requests.add(path);
    return {'token': 'synthetic'};
  }

  @override
  Future<dynamic> get(String path) async {
    requests.add(path);
    if (path == 'assignments') throw StateError('obsolete endpoint');
    if (path == 'places/recent?limit=20') return [];
    if (path == 'auth/me') {
      return {
        'id': 'user',
        'capabilities': ['locations'],
      };
    }
    if (path == 'collection-config') return <String, dynamic>{};
    lookups++;
    return {
      'recommended_mahalla_id': 'm',
      'mahallas': [
        {'id': 'm', 'name': 'Восстановленная', 'revision': 1, 'contains': true},
      ],
    };
  }
}

void main() {
  final fix = {'latitude': 39.495, 'longitude': 67.61, 'accuracy_m': 10};
  late GeographyServer server;
  late MemoryStore store;
  late CaptureController c;
  setUp(() async {
    server = GeographyServer();
    store = MemoryStore();
    c = CaptureController(server, store, Device())..authenticated = true;
    await c.save({'fix': fix});
  });
  test(
    'login succeeds without assignment data or an assignment request',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final api = RestoreServer();
      final controller = CaptureController(api, MemoryStore(), Device());
      await controller.login('mapper@example.test', 'synthetic');
      expect(controller.authenticated, true);
      expect(controller.error, isNull);
      expect(api.requests, contains('auth/me'));
      expect(api.requests, isNot(contains('assignments')));
    },
  );
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
      ..draft = store.value;
    expect(restored.addressPayload(fix), payload);
    await c.chooseAddress('street', 'unknown');
    expect(c.addressPayload(fix)['street'], null);
    expect(c.addressPayload(fix)['address_choices']['street'], {
      'status': 'unknown',
    });
  });
  test('empty fields are optional', () async {
    expect(c.addressPayload(fix)['mahalla_name'], isNull);
    expect(
      c.addressPayload(fix)['address_choices']['street']['status'],
      'unknown',
    );
  });
  test(
    'late suggestion response cannot replace newer point suggestions',
    () async {
      final old = c.suggest();
      await Future<void>.delayed(Duration.zero);
      await c.save({
        'fix': {...fix, 'latitude': 39.5},
      });
      final current = c.suggest();
      await Future<void>.delayed(Duration.zero);
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
    'fresh GPS preserves manual clearing and uses the entrance coordinate',
    () async {
      final fresh = CaptureController(server, store, FreshDevice())
        ..authenticated = true;
      await fresh.save({'fix': fix});
      await fresh.chooseAddress('mahalla', 'unknown');
      await fresh.chooseAddress('street', 'unknown');
      server.fail = true;
      await fresh.locate();
      expect((fresh.draft!['addressChoices'] as Map).length, 2);
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
  test(
    'session change preserves manual choices and ignores old response',
    () async {
      await c.chooseAddress('mahalla', 'unknown');
      final old = c.suggest();
      await Future<void>.delayed(Duration.zero);
      c.authenticated = false;
      c.authenticated = true;
      final changed = c.suggest();
      await Future<void>.delayed(Duration.zero);
      server.pending.last.complete({'recommended_mahalla_id': 'new'});
      await changed;
      server.pending.first.complete({'recommended_mahalla_id': 'old'});
      await old;
      expect(c.draft!['addressChoices']['mahalla']['status'], 'unknown');
      expect(c.suggestions!['recommended_mahalla_id'], 'new');
    },
  );
  Map<String, dynamic> reliable() => {
    'recommended_mahalla_id': 'm',
    'recommended_street_id': 's',
    'mahallas': [
      {'id': 'm', 'name': 'Махалля', 'revision': 2, 'contains': true},
    ],
    'streets': [
      {'id': 's', 'name': 'Улица', 'revision': 3, 'distance_m': 12},
    ],
    'street_radius_m': 50,
    'ambiguity_reasons': <String>[],
  };
  Future<void> lookup(Map<String, dynamic> result) async {
    final request = c.suggest();
    await Future<void>.delayed(Duration.zero);
    server.pending.last.complete(result);
    await request;
  }

  test(
    'reliable fields prefill and serialize without local provenance',
    () async {
      await lookup(reliable());
      expect(c.draft!['addressChoices']['mahalla']['provenance'], 'automatic');
      expect(c.addressPayload(fix)['street'], 'Улица');
      expect(c.addressPayload(fix)['address_choices']['street'], {
        'status': 'accepted',
        'reference_revision': 3,
        'selected_name': 'Улица',
      });
    },
  );
  for (final reason in [
    'near_mahalla_boundary',
    'overlapping_mahallas',
    'nearby_streets',
  ]) {
    test('reliability is independent for $reason', () async {
      await lookup({
        ...reliable(),
        'ambiguity_reasons': [reason],
      });
      final choices = c.draft!['addressChoices'] as Map;
      expect(choices.containsKey('mahalla'), reason == 'nearby_streets');
      expect(choices.containsKey('street'), reason != 'nearby_streets');
    });
  }
  test('poor and approximate GPS leave automatic fields empty', () async {
    for (final values in [
      {
        'fix': {...fix, 'accuracy_m': 31},
      },
      {'fix': fix, 'approximate': true},
    ]) {
      await c.save(values);
      await lookup(reliable());
      expect(c.draft!['addressChoices'], isEmpty);
    }
  });
  test('invalid references and missing candidates stay empty', () async {
    final result = reliable();
    (result['mahallas'] as List).first.remove('revision');
    result['streets'] = [];
    await lookup(result);
    expect(c.draft!['addressChoices'], isEmpty);
  });
  test(
    'multiple containing mahallas and out of radius street stay empty',
    () async {
      final result = reliable();
      (result['mahallas'] as List).add({'id': 'other', 'contains': true});
      result['street_radius_m'] = 5;
      await lookup(result);
      expect(c.draft!['addressChoices'], isEmpty);
    },
  );
  test(
    'lookup merges intervening manual edits and deliberate clearing',
    () async {
      final request = c.suggest();
      await Future<void>.delayed(Duration.zero);
      await c.chooseAddress('mahalla', 'corrected', name: 'Ручная');
      await c.chooseAddress('street', 'unknown');
      server.pending.last.complete(reliable());
      await request;
      expect(c.addressPayload(fix)['mahalla_name'], 'Ручная');
      expect(c.addressPayload(fix)['street'], isNull);
    },
  );
  test(
    'replacement rejects stale proposal or intervening manual edits',
    () async {
      await c.chooseAddress('street', 'corrected', name: 'Ручная');
      await lookup(reliable());
      final current = c.draft!['addressChoices']['street'] as Map;
      final proposed = c.reliableSuggestion('street')!;
      await c.chooseAddress('street', 'corrected', name: 'Новая');
      await c.replaceAddress('street', proposed, current);
      expect(c.addressPayload(fix)['street'], 'Новая');
      final latest = c.draft!['addressChoices']['street'] as Map;
      await c.replaceAddress('street', proposed, latest);
      expect(c.addressPayload(fix)['street'], 'Улица');
      expect(c.draft!['addressChoices']['street']['provenance'], 'manual');
    },
  );
  test(
    'legacy choices survive failed lookup while automatic values clear',
    () async {
      await lookup(reliable());
      await c.save({
        ...c.draft!,
        'addressChoices': {
          ...c.draft!['addressChoices'] as Map,
          'mahalla': {'status': 'corrected', 'name': 'Старая'},
        },
      });
      server.fail = true;
      await c.suggest();
      expect(c.addressPayload(fix)['mahalla_name'], 'Старая');
      expect(c.addressPayload(fix)['street'], isNull);
    },
  );
  test('location check rejects response even without a newer lookup', () async {
    final request = c.suggest();
    await Future<void>.delayed(Duration.zero);
    await c.save({
      ...c.draft!,
      'fix': {...fix, 'latitude': 40},
    });
    server.pending.last.complete(reliable());
    await request;
    expect(c.draft!['addressChoices'], isEmpty);
  });
  test('authenticated restored draft refreshes suggestions but frozen payload stays unchanged', () async {
    final api = RestoreServer();
    final restored = CaptureController(api, store, Device());
    await restored.save({'fix': fix, 'addressArea': 'area'});
    restored.draft = await store.read();
    await restored.access();
    expect(api.lookups, 1);
    expect(restored.addressPayload(fix)['mahalla_name'], 'Восстановленная');
    final frozen = {
      ...restored.draft!,
      'place': {'id': 'old', 'mahalla_name': 'Исходная'},
    };
    await restored.save(frozen);
    await restored.access();
    expect(api.lookups, 1);
    expect(restored.draft, frozen);
  });
  test('successful refresh clears automatic values and preserves selected reference', () async {
    await lookup(reliable());
    await c.chooseAddress(
      'mahalla',
      'accepted',
      reference: {'id': 'manual', 'name': 'Выбранная', 'revision': 7},
    );
    final fresh = CaptureController(server, store, FreshDevice())
      ..authenticated = true
      ..draft = store.value;
    server.fail = true;
    await fresh.locate();
    expect(fresh.addressPayload(fix)['mahalla_id'], 'manual');
    expect(fresh.addressPayload(fix)['street'], isNull);
  });
  test('failed GPS preserves address choices', () async {
    await lookup(reliable());
    final previous = c.draft;
    await c.run(c.locate);
    expect(c.draft, previous);
  });
  test('storage failure cannot apply automatic values in memory', () async {
    final request = c.suggest();
    await Future<void>.delayed(Duration.zero);
    store.fail = true;
    server.pending.last.complete(reliable());
    await request;
    expect(c.draft!['addressChoices'], isEmpty);
    expect(c.suggestionError, isNotNull);
  });
}
