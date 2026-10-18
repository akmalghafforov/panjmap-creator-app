import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/services.dart';
import 'package:panjmap_capture/main.dart';

import 'controller_test.dart' show MemoryStore, Device;

class AuthApi extends CaptureApi {
  AuthApi() : super('https://example.test/api/v1');
  dynamic options = {
    'development_role_login_enabled': true,
    'roles': [
      {'role': 'administrator', 'label': 'Administrator'},
      {'role': 'mapper', 'label': 'Mapper'},
    ],
  };
  Map<String, dynamic> me = {
    'id': 'admin-id',
    'role': 'administrator',
    'development_login': true,
    'capabilities': ['access'],
  };
  Completer<dynamic>? optionsGate, meGate;
  Completer<Map<String, dynamic>>? loginGate;
  final calls = <String>[];
  String? submittedRole;
  DateTime expiry = DateTime.now().add(const Duration(hours: 1));
  @override
  Future<dynamic> get(String path) async {
    calls.add(path);
    if (path == 'auth/options') {
      if (optionsGate != null) return optionsGate!.future;
      if (options is! Map) throw options;
      return options;
    }
    if (path == 'auth/me') return meGate?.future ?? me;
    if (path == 'collection-config') return <String, dynamic>{};
    if (path.startsWith('places/recent')) return [];
    throw StateError('Unexpected collection request: $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    dynamic body, {
    String? key,
    ProgressCallback? progress,
  }) async {
    calls.add(path);
    submittedRole = (body as Map)['role'] as String?;
    return loginGate?.future ?? credentials;
  }

  Map<String, dynamic> get credentials => {
    'token': 'synthetic-token',
    'expires_at': expiry.toUtc().toIso8601String(),
  };
}

class UnauthorizedAdapter implements HttpClientAdapter {
  final pending = Completer<ResponseBody>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == 'slow') return pending.future;
    return ResponseBody.fromString(
      '{"data":{"development_role_login_enabled":true,"roles":[]}}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'discovery replaces password fields and administrator can switch roles',
    (tester) async {
      final api = AuthApi();
      final c = CaptureController(api, MemoryStore(), Device());
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: CaptureScreen(controller: c)));
      await tester.pumpAndSettle();
      expect(find.text('Войти без пароля'), findsOneWidget);
      expect(find.text('Пароль'), findsNothing);
      await tester.tap(find.text('Войти без пароля'));
      await tester.pumpAndSettle();
      expect(api.submittedRole, 'administrator');
      expect(
        find.textContaining('Сбор полевых данных недоступен'),
        findsOneWidget,
      );
      expect(
        api.calls.where(
          (p) =>
              p != 'auth/options' &&
              p != 'auth/me' &&
              p != 'auth/development-login',
        ),
        isEmpty,
      );
      await tester.tap(find.text('Сменить роль'));
      await tester.pumpAndSettle();
      expect(c.authenticated, false);
      expect(find.text('Войти без пароля'), findsOneWidget);
      expect(await secureTokens.read(key: api.origin), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'discovery failure retains passwords and retry discovers empty setup',
    (tester) async {
      final api = AuthApi()..options = StateError('offline');
      final c = CaptureController(api, MemoryStore(), Device());
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: CaptureScreen(controller: c)));
      await tester.pumpAndSettle();
      expect(find.text('Пароль'), findsOneWidget);
      expect(find.text('Повторить проверку'), findsOneWidget);
      api.options = {'development_role_login_enabled': true, 'roles': []};
      await tester.tap(find.text('Повторить проверку'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Запустите seeder'), findsOneWidget);
      expect(find.text('Войти без пароля'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('disabled and 404 discovery use password fallback', () async {
    final api = AuthApi();
    final c = CaptureController(api, MemoryStore(), Device());
    addTearDown(c.dispose);
    api.options = {'development_role_login_enabled': false, 'roles': []};
    await c.loadAuthOptions();
    expect(c.developmentRoleLoginEnabled, false);
    api.options = DioException(
      requestOptions: RequestOptions(),
      response: Response(requestOptions: RequestOptions(), statusCode: 404),
    );
    await c.loadAuthOptions();
    expect(c.developmentRoleLoginEnabled, false);
    expect(c.optionsError, isNull);
  });

  test('repeated taps issue one request and store expiry metadata', () async {
    final api = AuthApi()..loginGate = Completer();
    final c = CaptureController(api, MemoryStore(), Device())
      ..selectedRole = 'administrator';
    addTearDown(c.dispose);
    final first = c.loginRole();
    await c.loginRole();
    expect(api.calls.where((p) => p == 'auth/development-login').length, 1);
    api.loginGate!.complete(api.credentials);
    await first;
    expect(c.authenticated, true);
    expect(c.collectionAvailable, false);
    final stored =
        jsonDecode((await secureTokens.read(key: api.origin))!) as Map;
    expect(stored['expires_at'], api.credentials['expires_at']);
  });

  test('restored admin skips collection; expiry preserves draft and clears credentials', () async {
    final api = AuthApi();
    FlutterSecureStorage.setMockInitialValues({
      api.origin: jsonEncode(api.credentials),
    });
    final store = MemoryStore()
      ..value = {
        'place': {'id': 'stable-uuid'},
        'account': 'admin-id',
        'file': 'photo-path',
      };
    final c = CaptureController(api, store, Device());
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.authenticated, true);
    expect(c.collectionAvailable, false);
    expect(api.calls.contains('collection-config'), false);
    c.expiresAt = DateTime.now().subtract(const Duration(seconds: 1));
    c.checkExpiry();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(c.authenticated, false);
    expect(c.draft!['place']['id'], 'stable-uuid');
    expect(c.draft!['file'], 'photo-path');
    expect(await secureTokens.read(key: api.origin), isNull);
    expect(c.developmentRoleLoginEnabled, true);
  });

  test('expired restoration makes no authenticated request', () async {
    final api = AuthApi()
      ..expiry = DateTime.now().subtract(const Duration(hours: 1));
    FlutterSecureStorage.setMockInitialValues({
      api.origin: jsonEncode(api.credentials),
    });
    final c = CaptureController(api, MemoryStore(), Device());
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.authenticated, false);
    expect(api.calls.contains('auth/me'), false);
    expect(await secureTokens.read(key: api.origin), isNull);
  });

  test('stale options and me cannot replace newer sign-in state', () async {
    final api = AuthApi()..optionsGate = Completer();
    final c = CaptureController(api, MemoryStore(), Device());
    addTearDown(c.dispose);
    final options = c.loadAuthOptions();
    await c.loginRole();
    api.optionsGate!.complete({
      'development_role_login_enabled': false,
      'roles': [],
    });
    await options;
    expect(c.authenticated, true);
    api.meGate = Completer();
    final access = c.access();
    final ending = c.endSession();
    api.meGate!.complete(api.me);
    await access;
    await ending;
    expect(c.authenticated, false);
  });

  test('late sign-in response cannot restore ended session', () async {
    final api = AuthApi()..loginGate = Completer();
    final c = CaptureController(api, MemoryStore(), Device());
    addTearDown(c.dispose);
    final login = c.loginRole();
    await c.endSession();
    api.loginGate!.complete(api.credentials);
    await login;
    expect(c.authenticated, false);
    expect(await secureTokens.read(key: api.origin), isNull);
  });
  test('foreground expiry timer ends the session', () async {
    final api = AuthApi()
      ..expiry = DateTime.now().add(const Duration(milliseconds: 150));
    final c = CaptureController(api, MemoryStore(), Device());
    addTearDown(c.dispose);
    await c.loginRole();
    expect(c.authenticated, true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.authenticated, false);
    expect(await secureTokens.read(key: api.origin), isNull);
  });

  testWidgets('resume checks expiry and returns to role selection', (
    tester,
  ) async {
    final api = AuthApi();
    final c = CaptureController(api, MemoryStore(), Device());
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(home: CaptureScreen(controller: c)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Войти без пароля'));
    await tester.pumpAndSettle();
    c.expiresAt = DateTime.now().subtract(const Duration(seconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(c.authenticated, false);
    expect(find.text('Войти без пароля'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('stale discovery cannot overwrite a more recent discovery', () async {
    final api = AuthApi()..optionsGate = Completer();
    final c = CaptureController(api, MemoryStore(), Device());
    addTearDown(c.dispose);
    final gate = api.optionsGate!;
    final first = c.loadAuthOptions();
    api.optionsGate = null;
    api.options = {'development_role_login_enabled': true, 'roles': []};
    await c.loadAuthOptions();
    gate.complete({'development_role_login_enabled': false, 'roles': []});
    await first;
    expect(c.developmentRoleLoginEnabled, true);
    expect(c.optionsLoading, false);
  });

  test('late sign-in failure cannot overwrite an ended session', () async {
    final api = AuthApi()..loginGate = Completer();
    final c = CaptureController(api, MemoryStore(), Device());
    addTearDown(c.dispose);
    final login = c.loginRole();
    await c.endSession();
    final error = c.error;
    api.loginGate!.completeError(StateError('old response'));
    await login;
    expect(c.error, error);
    expect(c.authenticated, false);
  });

  for (final stale in [false, true]) {
    test(
      'API 401 ${stale ? "ignores old tokens" : "clears current credentials"}',
      () async {
        final adapter = UnauthorizedAdapter();
        final api = CaptureApi(
          'https://example.test/api/v1',
          client: Dio(BaseOptions(baseUrl: 'https://example.test/api/v1/'))
            ..httpClientAdapter = adapter,
        );
        final c = CaptureController(api, MemoryStore(), Device())
          ..authenticated = true;
        addTearDown(c.dispose);
        api.token('old');
        await secureTokens.write(key: api.origin, value: 'old');
        final pending = api.get('slow');
        // Allow Dio to snapshot the old Authorization header.
        await Future<void>.delayed(Duration.zero);
        if (stale) api.token('new');
        adapter.pending.complete(ResponseBody.fromString('{}', 401));
        await expectLater(pending, throwsA(isA<DioException>()));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(c.authenticated, stale);
        expect(
          await secureTokens.read(key: api.origin),
          stale ? 'old' : isNull,
        );
      },
    );
  }
}
