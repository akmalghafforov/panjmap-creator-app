import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/services.dart';

class Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <String>[];
  String response = '{"data":{"id":"result"}}';
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(utf8.decode(bytes, allowMalformed: true));
    return ResponseBody.fromString(
      response,
      201,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'paginated helper preserves metadata and authenticated encoded queries',
    () async {
      final adapter = Adapter()
        ..response = '{"data":[],"meta":{"current_page":2,"last_page":3}}';
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api/v1/'))
        ..httpClientAdapter = adapter;
      final api = CaptureApi('https://example.test/api/v1', client: dio)
        ..token('secret');
      final query = Uri(
        queryParameters: {'q': 'Улица & сад', 'page': '2', 'per_page': '100'},
      ).query;
      final result = await api.getPage('geography/streets?$query');
      expect(result['meta']['last_page'], 3);
      expect(result['data'], isEmpty);
      expect(adapter.requests.single.uri.queryParameters['q'], 'Улица & сад');
      expect(adapter.requests.single.uri.path, '/api/v1/geography/streets');
      expect(adapter.requests.single.headers['Authorization'], 'Bearer secret');
      expect(await api.get('geography/mahallas'), isEmpty);
    },
  );
  test('capture PATCH and thumbnails use authenticated endpoints', () async {
    final adapter = Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api/v1/'))
      ..httpClientAdapter = adapter;
    final api = CaptureApi('https://example.test/api/v1', client: dio)
      ..token('secret');
    final command = {
      'place': {'base_revision': 2, 'house_number': '12'},
    };
    await api.patchCapture('p', command, 'stable-key');
    expect(adapter.requests.last.method, 'PATCH');
    expect(adapter.requests.last.uri.path, '/api/v1/places/p/capture');
    expect(adapter.requests.last.headers['Idempotency-Key'], 'stable-key');
    expect(jsonDecode(adapter.bodies.last), command);
    await api.thumbnail('f');
    expect(adapter.requests.last.uri.path, '/api/v1/photos/f/content');
    expect(adapter.requests.last.uri.queryParameters, {'variant': 'thumbnail'});
    expect(adapter.requests.last.headers['Authorization'], 'Bearer secret');
    expect(adapter.requests.last.responseType, ResponseType.bytes);
  });
  test(
    'Contract paths, bearer, JSON and multipart retry keys remain stable',
    () async {
      final adapter = Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api/v1/'))
        ..httpClientAdapter = adapter;
      final api = CaptureApi('https://example.test/api/v1', client: dio)
        ..token('secret');
      await api.post('places', {
        'id': 'p',
        'type': 'shop',
        'source_type': 'field_observation',
      }, key: 'pk');
      expect(
        jsonDecode(adapter.bodies.first),
        isNot(contains('collection_area_id')),
      );
      expect(adapter.requests.first.uri.path, '/api/v1/places');
      expect(adapter.requests.first.headers['Authorization'], 'Bearer secret');
      expect(
        jsonDecode(adapter.bodies.first)['source_type'],
        'field_observation',
      );
      for (var i = 0; i < 2; i++) {
        await api.post(
          'entrances/e/photos',
          FormData.fromMap({
            'id': 'f',
            'captured_at': '2026-01-01T00:00:00Z',
            'photo': MultipartFile.fromBytes([
              1,
              2,
              3,
            ], filename: 'entrance.jpg'),
          }),
          key: 'fk',
        );
      }
      expect(adapter.requests.last.uri.path, '/api/v1/entrances/e/photos');
      expect(
        adapter.requests
            .skip(1)
            .every((r) => r.headers['Idempotency-Key'] == 'fk'),
        true,
      );
      expect(adapter.bodies.last, contains('name="photo"'));
      expect(adapter.bodies.last, contains('name="captured_at"'));
      expect(adapter.bodies.last, contains('name="id"'));
    },
  );
}
