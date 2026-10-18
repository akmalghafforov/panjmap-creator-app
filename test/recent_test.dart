import 'dart:async';
import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/services.dart';

import 'controller_test.dart' show MemoryStore, Device;

class RecentApi extends CaptureApi {
  RecentApi() : super('https://example.test');
  Completer<dynamic> result = Completer<dynamic>();
  @override
  Future<dynamic> get(String path) => result.future;
}

void main() {
  test('history 401 expires the session without changing the draft', () async {
    final api = RecentApi();
    final c = CaptureController(api, MemoryStore(), Device())..authenticated = true;
    await c.save({'saved': true});
    final load = c.refreshRecentObjects();
    api.result.completeError(DioException(requestOptions: RequestOptions(), response: Response(requestOptions: RequestOptions(), statusCode: 401)));
    await load;
    expect(c.authenticated, false);
    expect(c.error, contains('Сессия истекла'));
    expect(c.recentObjects, isEmpty);
    expect(c.draft, {'saved': true});
    expect(c.busy, false);
  });
  test('recent loading is independent, retains rows on failure and ignores old sessions', () async {
    final api = RecentApi();
    final c = CaptureController(api, MemoryStore(), Device())
      ..authenticated = true;
    await c.save({'saved': true});
    c.error = 'form error';
    final load = c.refreshRecentObjects();
    expect(c.recentLoading, true);
    expect(c.busy, false);
    api.result.complete([
      {'id': 'one'},
    ]);
    await load;
    expect(c.recentObjects.single['id'], 'one');
    api.result = Completer<dynamic>();
    final fail = c.refreshRecentObjects();
    api.result.completeError(StateError('offline'));
    await fail;
    expect(c.recentError, isNotNull);
    expect(c.recentObjects, hasLength(1));
    expect(c.error, 'form error');
    expect(c.draft, {'saved': true});
    api.result = Completer<dynamic>();
    final stale = c.refreshRecentObjects();
    c.authenticated = false;
    c.authenticated = true;
    api.result.complete([
      {'id': 'old user'},
    ]);
    await stale;
    expect(c.recentObjects, isEmpty);
    expect(c.recentLoading, false);
  });
}
