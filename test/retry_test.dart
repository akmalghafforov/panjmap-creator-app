import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/services.dart';

import 'controller_test.dart' show MemoryStore, Device;

class Server extends CaptureApi {
  Server() : super('https://example.test/api/v1');
  final records = <String, Map<String, dynamic>>{};
  final writes = <String>[];
  bool lose = true;
  int recentReads = 0;
  @override
  Future<dynamic> get(String path) async {
    if (path == 'places/recent?limit=20') {
      recentReads++;
      return records.entries
          .where((e) => e.key.startsWith('places/'))
          .map((e) => e.value)
          .toList();
    }
    if (records.containsKey(path)) {
      return records[path];
    }
    throw DioException(
      requestOptions: RequestOptions(path: path),
      response: Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 404,
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    dynamic body, {
    String? key,
    ProgressCallback? progress,
  }) async {
    final data = Map<String, dynamic>.from(body as Map);
    writes.add('$path:$key');
    records['$path/${data['id']}'] = data;
    if (lose) {
      lose = false;
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.receiveTimeout,
      );
    }
    return data;
  }
}

void main() {
  test(
    'Lost create response reconciles after restart without duplicate write',
    () async {
      final server = Server(), store = MemoryStore();
      final c = CaptureController(server, store, Device())
        ..authenticated = true
        ..account = 'a';
      await c.save({
        'origin': server.origin,
        'account': 'a',
        'place': {'id': 'p', 'type': 'shop'},
        'entrance': {'id': 'e', 'place_id': 'p'},
        'photoId': 'f',
        'placeKey': 'pk',
        'entranceKey': 'ek',
        'photoKey': 'fk',
        'file': 'missing',
        'size': 1,
        'captured_at': '2026-01-01T00:00:00Z',
      });
      await c.submit();
      expect(server.writes, ['places:pk']);
      final restored = CaptureController(server, store, Device())
        ..authenticated = true
        ..account = 'a'
        ..draft = store.value;
      await restored.submit();
      expect(server.writes, ['places:pk', 'entrances:ek']);
      expect(restored.draft!['placeDone'], true);
      expect(restored.draft!['entranceDone'], true);
      expect(restored.draft!['photoId'], 'f');
      expect(server.recentReads, 1);
      expect(restored.recentObjects.single['id'], 'p');
    },
  );
  test(
    'legacy frozen payload rotates its persisted key once and reconciles UUID',
    () async {
      final server = Server(), store = MemoryStore();
      server.records['places/p'] = {'id': 'p', 'type': 'shop'};
      final c = CaptureController(server, store, Device())
        ..authenticated = true
        ..account = 'a';
      await c.save({
        'origin': server.origin,
        'account': 'a',
        'addressArea': 'old',
        'place': {'id': 'p', 'type': 'shop', 'collection_area_id': 'old'},
        'entrance': {'id': 'e', 'place_id': 'p'},
        'placeKey': 'old-key',
        'entranceKey': 'ek',
        'photoId': 'f',
        'photoKey': 'fk',
        'file': 'missing',
        'size': 1,
        'captured_at': '2026-01-01T00:00:00Z',
      });
      await c.normalizeDraft();
      final key = store.value!['placeKey'];
      expect(key, isNot('old-key'));
      expect(store.value!.containsKey('addressArea'), false);
      expect(
        (store.value!['place'] as Map).containsKey('collection_area_id'),
        false,
      );
      await c.normalizeDraft();
      expect(store.value!['placeKey'], key);
      await c.submit();
      expect(c.draft!['placeDone'], true);
      expect(c.draft!['place']['id'], 'p');
      expect(server.writes, ['entrances:ek']);
      expect(store.value!['placeKey'], key);
    },
  );
  test('legacy normalization must persist before network writes', () async {
    final server = Server(), store = MemoryStore();
    final c = CaptureController(server, store, Device())
      ..authenticated = true
      ..account = 'a';
    await c.save({
      'place': {'id': 'p', 'collection_area_id': 'old'},
      'placeKey': 'old',
    });
    store.fail = true;
    await c.submit();
    expect(server.writes, isEmpty);
    expect(c.draft!['placeKey'], 'old');
    expect(c.error, isNotNull);
  });
  test('Inconsistent UUID stops before another write', () async {
    final server = Server();
    server.records['places/p'] = {'id': 'p', 'type': 'other'};
    final c = CaptureController(server, MemoryStore(), Device())
      ..authenticated = true
      ..account = 'a';
    await c.save({
      'origin': server.origin,
      'account': 'a',
      'place': {'id': 'p', 'type': 'shop'},
      'placeKey': 'pk',
    });
    await c.submit();
    expect(server.writes, isEmpty);
    expect(c.error, contains('Несовпадение'));
  });
}
