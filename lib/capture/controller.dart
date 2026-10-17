import 'dart:io';

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
  bool busy = false, authenticated = false;
  double progress = 0;
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
    if (!(me['capabilities'] as List).contains('locations') || areas.isEmpty) {
      throw StateError(
        'Нет назначения для сбора объектов. Обратитесь к администратору.',
      );
    }
    authenticated = true;
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
    final p = await device.position();
    final approximate = await device.approximate();
    await save({
      ...?draft,
      'fix': GpsFix(p.latitude, p.longitude, p.accuracy, p.timestamp).toJson(),
      'approximate': approximate,
    });
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
      for (final key in payload.keys) {
        final expected = payload[key], actual = found[key];
        final same = expected is num
            ? actual != null &&
                  double.tryParse('$actual') == expected.toDouble()
            : key.endsWith('_at') || key == 'fix_time'
            ? actual != null &&
                  DateTime.parse('$actual')
                      .isAtSameMomentAs(DateTime.parse('$expected'))
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

  Future<void> next() => run(() async {
    if (!complete) {
      return;
    }
    final path = draft!['file'] as String;
    await store.clear();
    draft = null;
    status = '';
    final f = File(path);
    if (await f.exists()) {
      await f.delete();
    }
  });
}
