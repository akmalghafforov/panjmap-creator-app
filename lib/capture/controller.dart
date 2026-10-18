import 'dart:io';
import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'services.dart';
import 'models.dart';

import 'package:flutter/services.dart';

class CaptureController extends ChangeNotifier {
  final CaptureApi api;
  final DraftStore store;
  final CaptureDevice device;
  CaptureController(this.api, this.store, this.device);
  Map<String, dynamic>? draft;
  Map<String, dynamic> config = {};
  List<Map<String, dynamic>> areas = [];
  String? account, area, type, error;
  String name = '', status = '';
  bool busy = false;
  bool _authenticated = false;
  int sessionGeneration = 0;
  bool get authenticated => _authenticated;
  set authenticated(bool value) {
    if (_authenticated == value) return;
    _authenticated = value;
    sessionGeneration++;
    recentObjects = [];
    recentError = null;
    recentLoading = false;
    _recentRequest = null;
    mapPosition = null;
    mapMessage = null;
    mapLoading = false;
    _mapRequest = null;
  }

  List<Map<String, dynamic>> recentObjects = [];
  bool recentLoading = false;
  String? recentError;
  Future<void>? _recentRequest;

  Future<void> refreshRecentObjects() {
    if (!authenticated) return Future.value();
    return _recentRequest ??= _refreshRecentObjects(sessionGeneration);
  }

  Future<void> _refreshRecentAfterCreation(int session) async {
    // An in-flight request may have read the list before this place existed.
    final pending = _recentRequest;
    if (pending != null) await pending;
    if (session != sessionGeneration || !authenticated) return;
    await refreshRecentObjects();
  }

  Future<void> _refreshRecentObjects(int session) async {
    recentLoading = true;
    recentError = null;
    notifyListeners();
    try {
      final rows =
          await Future.sync(() => api.get('places/recent?limit=20')) as List;
      if (session != sessionGeneration || !authenticated) return;
      recentObjects = rows
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    } catch (e) {
      if (session != sessionGeneration || !authenticated) return;
      if (e is DioException && e.response?.statusCode == 401) {
        error = message(e);
      } else {
        recentError = 'Не удалось загрузить объекты. Повторите попытку.';
      }
    } finally {
      if (session == sessionGeneration) {
        recentLoading = false;
        _recentRequest = null;
      }
      notifyListeners();
    }
  }

  Position? mapPosition;
  bool mapLoading = false;
  String? mapMessage;
  int mapRevision = 0;
  Future<void>? _mapRequest;

  Future<void> refreshMapLocation() {
    if (!authenticated) return Future.value();
    return _mapRequest ??= _refreshMapLocation(sessionGeneration);
  }

  Future<void> _refreshMapLocation(int session) async {
    mapLoading = true;
    notifyListeners();
    try {
      final position = await device.position();
      if (session != sessionGeneration || !authenticated) return;
      mapPosition = position;
      mapMessage = null;
      mapRevision++;
    } catch (e) {
      if (session != sessionGeneration || !authenticated) return;
      mapPosition = null;
      mapRevision++;
      mapMessage = e is TimeoutException
          ? 'Не удалось получить местоположение за 30 секунд. Показан Пенджикент.'
          : 'Местоположение недоступно. Проверьте разрешение и включите геолокацию. Показан Пенджикент.';
    } finally {
      if (session == sessionGeneration) {
        mapLoading = false;
        _mapRequest = null;
        notifyListeners();
      }
    }
  }

  double progress = 0;
  int _lookupGeneration = 0;
  Map<String, dynamic>? suggestions;
  String? suggestionError;
  Map<String, dynamic>? _suggestionFix;
  String? _suggestionArea;

  Future<void> changeArea(String? value) async {
    if (frozen || area == value) return;
    area = value;
    _lookupGeneration++;
    suggestions = null;
    if (draft != null) {
      await save({
        ...draft!,
        'addressChoices': manualChoices(),
        'addressArea': area,
      });
    }
    await suggest();
  }

  Future<void> suggest() async {
    if (frozen || area == null || draft?['fix'] == null) return;
    final generation = ++_lookupGeneration;
    await save({
      ...draft!,
      'addressChoices': manualChoices(),
      'addressArea': area,
    });
    if (generation != _lookupGeneration || frozen) return;
    final fix = Map<String, dynamic>.from(draft!['fix'] as Map);
    final lookupArea = area;
    suggestions = null;
    suggestionError = null;
    notifyListeners();
    try {
      final query = Uri(
        queryParameters: {
          'collection_area_id': lookupArea!,
          'latitude': '${fix['latitude']}',
          'longitude': '${fix['longitude']}',
          'accuracy_m': '${fix['accuracy_m']}',
        },
      ).query;
      final result = await api.get('geography/suggestions?$query');
      if (generation != _lookupGeneration || frozen || area != lookupArea) {
        return;
      }
      if (!_deepEqual(draft?['fix'], fix)) return;
      suggestions = Map<String, dynamic>.from(result as Map);
      _suggestionFix = fix;
      _suggestionArea = lookupArea;
      final choices = manualChoices();
      for (final key in ['mahalla', 'street']) {
        final candidate = reliableSuggestion(key);
        if (!choices.containsKey(key) && candidate != null) {
          choices[key] = referenceChoice(candidate, 'automatic');
        }
      }
      await save({...draft!, 'addressChoices': choices, 'addressArea': area});
    } catch (_) {
      if (generation != _lookupGeneration || frozen) return;
      suggestionError = 'Подсказки недоступны. Введите название вручную или оставьте поле пустым.';
    }
    notifyListeners();
  }

  Map<String, dynamic> manualChoices() => {
    for (final entry in (draft?['addressChoices'] as Map? ?? {}).entries)
      if ((entry.value as Map)['provenance'] != 'automatic')
        entry.key as String: entry.value,
  };

  Map<String, dynamic> referenceChoice(Map reference, String provenance) => {
    'status': 'accepted',
    'provenance': provenance,
    'name': reference['name'],
    'id': reference['id'],
    'reference_revision': reference['revision'],
    'selected_name': reference['name'],
  };

  Map<String, dynamic>? reliableSuggestion(String key) {
    if (_suggestionArea != area || !_deepEqual(_suggestionFix, draft?['fix'])) {
      return null;
    }
    final accuracy = draft?['fix']?['accuracy_m'];
    if (draft?['approximate'] == true ||
        accuracy is! num ||
        !accuracy.isFinite ||
        accuracy < 0 ||
        accuracy > 30) {
      return null;
    }
    final data = suggestions;
    if (data == null) return null;
    final reasons = data['ambiguity_reasons'] as List? ?? [];
    final candidates =
        (data[key == 'mahalla' ? 'mahallas' : 'streets'] as List? ?? [])
            .whereType<Map>()
            .toList();
    final recommended = data['recommended_${key}_id'];
    final matching = candidates.where((r) => r['id'] == recommended).toList();
    if (recommended == null || matching.length != 1) return null;
    final candidate = matching.single;
    if (candidate['name'] is! String ||
        (candidate['name'] as String).trim().isEmpty ||
        candidate['id'].toString().trim().isEmpty ||
        candidate['revision'] == null ||
        candidate['revision'].toString().trim().isEmpty) {
      return null;
    }
    if (key == 'mahalla') {
      if (reasons.contains('near_mahalla_boundary') ||
          reasons.contains('overlapping_mahallas') ||
          candidates.where((r) => r['contains'] == true).length != 1 ||
          candidate['contains'] != true) {
        return null;
      }
    } else {
      final distance = candidate['distance_m'];
      final radius = data['street_radius_m'];
      if (reasons.contains('nearby_streets') ||
          distance is! num ||
          radius is! num ||
          !distance.isFinite ||
          !radius.isFinite ||
          distance < 0 ||
          distance > radius ||
          candidates.any(
            (r) => r['distance_m'] is num && r['distance_m'] < distance,
          )) {
        return null;
      }
    }
    return Map<String, dynamic>.from(candidate);
  }

  Future<void> replaceAddress(
    String key,
    Map<String, dynamic> proposed,
    Map current,
  ) async {
    if (!_deepEqual((draft?['addressChoices'] as Map?)?[key], current) ||
        !_deepEqual(reliableSuggestion(key), proposed)) {
      return;
    }
    await chooseAddress(key, 'accepted', reference: proposed);
  }

  Future<List<Map<String, dynamic>>> searchAddress(
    String kind,
    String query,
  ) async {
    if (area == null) return [];
    final params = Uri(
      queryParameters: {'collection_area_id': area!, 'q': query},
    ).query;
    return (await api.get('geography/$kind?$params') as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  Future<void> chooseAddress(
    String key,
    String status, {
    Map<String, dynamic>? reference,
    String? name,
  }) async {
    if (frozen || draft?['fix'] == null) return;
    if (status == 'corrected' && (name == null || name.trim().isEmpty)) {
      throw StateError('Введите название.');
    }
    final choices = Map<String, dynamic>.from(
      draft?['addressChoices'] as Map? ?? {},
    );
    choices[key] = {
      'status': status,
      'provenance': 'manual',
      if (status != 'unknown')
        'name': status == 'accepted' ? reference!['name'] : name!.trim(),
      if (reference != null && status != 'unknown') ...{
        'id': reference['id'],
        'reference_revision': reference['revision'],
        'selected_name': reference['name'],
      },
    };
    await save({...draft!, 'addressChoices': choices, 'addressArea': area});
    notifyListeners();
  }

  Map<String, dynamic> addressPayload(Map<String, dynamic> fix) {
    final choices = draft?['addressChoices'] as Map?;
    final metadata = <String, dynamic>{
      'lookup': {
        'latitude': fix['latitude'],
        'longitude': fix['longitude'],
        'accuracy_m': fix['accuracy_m'],
      },
    };
    final payload = <String, dynamic>{};
    for (final key in ['mahalla', 'street']) {
      final choice = choices?[key] as Map? ?? {'status': 'unknown'};
      payload['${key}_id'] = choice['id'];
      payload[key == 'street' ? 'street' : 'mahalla_name'] = choice['name'];
      metadata[key] = {
        'status': choice['status'],
        if (choice['reference_revision'] != null)
          'reference_revision': choice['reference_revision'],
        if (choice['selected_name'] != null)
          'selected_name': choice['selected_name'],
      };
    }
    payload['address_choices'] = metadata;
    return payload;
  }

  bool get frozen => draft?['place'] != null;
  bool get complete => draft?['photoDone'] == true;
  Future<void> run(Future<void> Function() work) async {
    if (busy) {
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      await work();
    } catch (e) {
      error = message(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  String message(Object e) {
    if (e is DioException) {
      if (e.response?.statusCode == 401) {
        authenticated = false;
      }
      return switch (e.response?.statusCode) {
        401 => 'Сессия истекла. Войдите снова; запись сохранена.',
        403 => 'Нет доступа. Обратитесь к администратору.',
        404 => 'Запись недоступна. Проверьте назначение с администратором.',
        409 => 'Конфликт записи. Повторите для проверки UUID; при повторном конфликте обратитесь к администратору.',
        413 => 'Фото превышает лимит сервера.',
        422 => 'Сервер отклонил данные. Проверьте конфигурацию и обратитесь к администратору.',
        429 => 'Слишком много запросов. Повторите позже.',
        _ => 'Нет подтверждения сервера. Запись сохранена; повторите отправку.',
      };
    }
    if (e is PlatformException) {
      return 'Камера недоступна или доступ запрещён. Разрешите камеру в настройках и повторите.';
    }
    return e.toString();
  }

  Future<void> initialize() => run(() async {
    draft = await store.read();
    if (!frozen) {
      await capture(recover: true);
    }
    final token = await secureTokens.read(key: api.origin);
    if (complete) {
      status = 'Запись сохранена. Проверьте обработку фото.';
    }
    if (token != null) {
      api.token(token);
      await access();
    }
  });
  Future<void> login(String email, String password) => run(() async {
    final r = await api.post('auth/login', {
      'email': email,
      'password': password,
      'device_label': 'Panjmap Android',
    });
    api.token(r['token'] as String);
    await secureTokens.write(key: api.origin, value: r['token'] as String);
    await access();
  });
  Future<void> access() async {
    final me = await api.get('auth/me');
    if (account != me['id'] && authenticated) authenticated = false;
    account = me['id'] as String;
    config = Map<String, dynamic>.from(
      await api.get('collection-config') as Map,
    );
    final assignments = await api.get('assignments') as List;
    areas = assignments.map((a) => Map<String, dynamic>.from(a as Map)).where((
      a,
    ) {
      final c = a['capabilities'];
      return c == null ||
          (c is List
              ? c.contains('locations')
              : c.toString().contains('locations'));
    }).toList();
    if (areas.length == 1) {
      area = areas.first['collection_area_id'] as String;
    }
    if (!frozen &&
        draft?['addressArea'] != null &&
        areas.any((a) => a['collection_area_id'] == draft!['addressArea'])) {
      area = draft!['addressArea'] as String;
    }
    if (!(me['capabilities'] as List).contains('locations') || areas.isEmpty) {
      throw StateError(
        'Нет назначения для сбора объектов. Обратитесь к администратору.',
      );
    }
    authenticated = true;
    unawaited(refreshMapLocation());
    unawaited(refreshRecentObjects());
    if (!frozen) await suggest();
  }

  Future<void> save(Map<String, dynamic> next) async {
    await store.write(next);
    draft = next;
  }

  Future<void> capture({bool recover = false}) async {
    if (frozen) {
      return;
    }
    final photo = await device.photo(recover: recover);
    if (photo == null) {
      return;
    }
    final bytes = await photo.readAsBytes();
    final format = img.findDecoderForData(bytes);
    final decoded = format?.startDecode(bytes);
    if (decoded == null ||
        !(format is img.JpegDecoder ||
            format is img.PngDecoder ||
            format is img.WebPDecoder)) {
      throw StateError('Поддерживаются JPEG, PNG и WebP.');
    }
    if (bytes.length > ((config['photo_max_kb'] as num?) ?? 10240) * 1024 ||
        decoded.width * decoded.height >
            ((config['photo_max_pixels'] as num?) ?? 24000000) ||
        decoded.width > 12000 ||
        decoded.height > 12000) {
      throw StateError('Фото превышает допустимый размер.');
    }
    if (format!.decodeFrame(0) == null) {
      throw StateError('Повреждённое фото. Повторите съёмку.');
    }
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/${const Uuid().v4()}.capture');
    await f.writeAsBytes(bytes, flush: true);
    try {
      await save({
        ...?draft,
        'file': f.path,
        'captured_at': DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
          isUtc: true,
        ).toIso8601String(),
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      });
    } catch (_) {
      await f.delete();
      rethrow;
    }
  }

  Future<void> locate() async {
    if (frozen) {
      return;
    }
    final generation = ++_lookupGeneration;
    final session = sessionGeneration;
    final p = await device.position();
    if (session == sessionGeneration && authenticated) {
      mapPosition = p;
      mapMessage = null;
      mapRevision++;
      notifyListeners();
    }
    if (generation != _lookupGeneration || frozen) return;
    final approximate = await device.approximate();
    if (generation != _lookupGeneration || frozen) return;
    await save({
      ...?draft,
      'fix': GpsFix(p.latitude, p.longitude, p.accuracy, p.timestamp).toJson(),
      'approximate': approximate,
      'addressChoices': manualChoices(),
      'addressArea': area,
    });
    await suggest();
  }

  Future<void> submit() => run(() async {
    if (!authenticated) {
      throw StateError('Войдите в систему.');
    }
    if (!frozen) {
      if (area == null ||
          type == null ||
          draft?['file'] == null ||
          draft?['fix'] == null) {
        throw StateError('Выберите участок, тип, фото и координаты.');
      }
      final fix = Map<String, dynamic>.from(draft!['fix'] as Map);
      if (DateTime.now()
              .toUtc()
              .difference(DateTime.parse(fix['fix_time'] as String))
              .inSeconds >
          120) {
        throw StateError('Обновите координаты: прошло более двух минут.');
      }
      final photoBytes = await File(draft!['file'] as String).readAsBytes();
      final info = img.findDecoderForData(photoBytes)?.startDecode(photoBytes);
      if (info == null ||
          photoBytes.length > (config['photo_max_kb'] as num) * 1024 ||
          info.width * info.height > (config['photo_max_pixels'] as num)) {
        throw StateError(
          'Фото превышает текущие лимиты сервера. Повторите съёмку.',
        );
      }
      final address = addressPayload(fix);
      const uuid = Uuid();
      final place = uuid.v4();
      final entrance = uuid.v4();
      await save({
        ...draft!,
        'origin': api.origin,
        'account': account,
        'place': {
          'id': place,
          'collection_area_id': area,
          'type': type,
          'name': name.trim().isEmpty ? null : name.trim(),
          'source_type': 'field_observation',
          ...address,
        },
        'entrance': {
          'id': entrance,
          'place_id': place,
          ...fix,
          'source_type': 'field_observation',
        },
        'photoId': uuid.v4(),
        'placeKey': uuid.v4(),
        'entranceKey': uuid.v4(),
        'photoKey': uuid.v4(),
      });
    }
    if (draft!['origin'] != api.origin || draft!['account'] != account) {
      throw StateError('Продолжите с исходным сервером и учётной записью.');
    }
    for (final stage in ['place', 'entrance', 'photo']) {
      final wasDone = draft!['${stage}Done'] == true;
      status = switch (stage) {
        'place' => 'Создание объекта',
        'entrance' => 'Сохранение координат',
        _ => 'Загрузка фото',
      };
      notifyListeners();
      final isPhoto = stage == 'photo';
      final payload = isPhoto
          ? {
              'id': draft!['photoId'],
              'entrance_id': (draft!['entrance'] as Map)['id'],
              'captured_at': draft!['captured_at'],
              'size_bytes': draft!['size'],
            }
          : Map<String, dynamic>.from(draft![stage] as Map);
      final path = isPhoto ? 'photos' : '${stage}s';
      // Persist before every network operation, including reconciliation.
      await save({...draft!});
      Map<String, dynamic>? found;
      try {
        found = Map<String, dynamic>.from(
          await api.get('$path/${payload['id']}') as Map,
        );
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) {
          rethrow;
        }
      }
      if (found == null && wasDone) {
        throw StateError(
          'Принятая запись недоступна. Обратитесь к администратору; UUID сохранены.',
        );
      }
      if (found == null) {
        try {
          if (isPhoto) {
            final f = File(draft!['file'] as String);
            if (await f.length() != draft!['size'] ||
                sha256.convert(await f.readAsBytes()).toString() !=
                    draft!['sha256']) {
              throw StateError('Файл повреждён. Обратитесь к администратору.');
            }
            found = await api.post(
              'entrances/${payload['entrance_id']}/photos',
              FormData.fromMap({
                'id': payload['id'],
                'captured_at': payload['captured_at'],
                'photo': await MultipartFile.fromFile(
                  f.path,
                  filename: 'entrance.jpg',
                ),
              }),
              key: draft!['photoKey'] as String,
              progress: (sent, total) {
                progress = total > 0 ? sent / total : 0;
                if (sent == total) {
                  status = 'Ожидание подтверждения';
                }
                notifyListeners();
              },
            );
          } else {
            found = await api.post(
              path,
              payload,
              key: draft!['${stage}Key'] as String,
            );
          }
        } on DioException catch (e) {
          if (e.response?.statusCode != 409) {
            rethrow;
          }
          found = Map<String, dynamic>.from(
            await api.get('$path/${payload['id']}') as Map,
          );
        }
      }
      if (stage == 'place') {
        unawaited(_refreshRecentAfterCreation(sessionGeneration));
      }
      for (final key in payload.keys) {
        final expected = payload[key], actual = found[key];
        final same = expected is num
            ? actual != null &&
                  double.tryParse('$actual') == expected.toDouble()
            : key.endsWith('_at') || key == 'fix_time'
            ? actual != null &&
                  DateTime.parse('$actual')
                      .isAtSameMomentAs(DateTime.parse('$expected'))
            : expected is Map || expected is List
            ? _deepEqual(actual, expected)
            : actual == expected;
        if (!same) {
          throw StateError(
            'Несовпадение $stage: $key. Сохраните UUID и обратитесь к администратору.',
          );
        }
      }
      await save({...draft!, '${stage}Done': true});
    }
    await poll();
  });
  Future<void> poll() async {
    status = 'Запись сохранена. Обработка фото';
    notifyListeners();
    for (var i = 0; i < 15; i++) {
      final p = await api.get('photos/${draft!['photoId']}');
      final state = p['processing_state'];
      status = state == 'failed'
          ? 'Запись сохранена. Обработка не удалась; сообщите UUID администратору. Не создавайте фото повторно.'
          : state == 'processed'
          ? 'Запись сохранена. Фото обработано.'
          : 'Запись сохранена. Фото ожидает обработки.';
      notifyListeners();
      if (state == 'failed' || state == 'processed') {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  bool _deepEqual(dynamic a, dynamic b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          b.keys.every((k) => a.containsKey(k) && _deepEqual(a[k], b[k]));
    }
    if (a is List && b is List) return jsonEncode(a) == jsonEncode(b);
    return a == b;
  }

  Future<void> next() => run(() async {
    if (!complete) {
      return;
    }
    final path = draft!['file'] as String;
    await store.clear();
    draft = null;
    _lookupGeneration++;
    suggestions = null;
    status = '';
    final f = File(path);
    if (await f.exists()) {
      await f.delete();
    }
  });
}
