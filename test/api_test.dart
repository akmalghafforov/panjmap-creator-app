import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/services.dart';

class Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <String>[];
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
      '{"data":{"id":"result"}}',
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
