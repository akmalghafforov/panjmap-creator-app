import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

abstract class DraftStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
  Future<void> clear();
}

class FileDraftStore implements DraftStore {
  final String name;
  FileDraftStore({this.name = 'draft.json'});
  Future<File> get file async =>
      File('${(await getApplicationSupportDirectory()).path}/$name');
  @override
  Future<Map<String, dynamic>?> read() async {
    final f = await file;
    return await f.exists()
        ? jsonDecode(await f.readAsString()) as Map<String, dynamic>
        : null;
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    final f = await file;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> clear() async {
    final f = await file;
    if (await f.exists()) {
      await f.delete();
    }
  }
}

abstract class CaptureDevice {
  Future<XFile?> photo({bool recover = false});
  Future<void> prepareLocation({bool request = true});
  Future<Position> position();
  Future<bool> approximate();
}

class AndroidCapture implements CaptureDevice {
  final picker = ImagePicker();
  @override
  Future<XFile?> photo({bool recover = false}) async {
    if (recover) {
      final lost = await picker.retrieveLostData();
      if (lost.exception != null) {
        throw lost.exception!;
      }
      return lost.files?.firstOrNull;
    }
    return picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
  }

  Future<void>? _permission;
  @override
  Future<void> prepareLocation({bool request = true}) {
    return _permission ??= _prepareLocation(request)
        .whenComplete(() => _permission = null);
  }

  Future<void> _prepareLocation(bool request) async {
    var p = await Geolocator.checkPermission();
    if (request && p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      throw StateError('Разрешите геолокацию в настройках приложения.');
    }
  }

  @override
  Future<Position> position() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Включите геолокацию в настройках.');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 30),
      ),
    );
  }

  @override
  Future<bool> approximate() async =>
      await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced;
}

class CaptureApi {
  final Dio dio;
  final String origin;
  CaptureApi(this.origin, {Dio? client})
    : dio =
          client ??
          Dio(
            BaseOptions(
              baseUrl: '$origin/',
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 45),
              sendTimeout: const Duration(seconds: 60),
            ),
          );
  void token(String value) {
    dio.options.headers['Authorization'] = 'Bearer $value';
  }

  Future<dynamic> get(String path) async =>
      (await dio.get<dynamic>(path)).data['data'];
  Future<Map<String, dynamic>> getPage(String path) async =>
      Map<String, dynamic>.from((await dio.get<dynamic>(path)).data as Map);

  Future<List<int>> thumbnail(String id) async => (await dio.get<List<int>>(
    'photos/$id/content?variant=thumbnail',
    options: Options(responseType: ResponseType.bytes),
  )).data!;

  Future<Map<String, dynamic>> patchCapture(
    String id,
    Map<String, dynamic> command,
    String key,
  ) async => Map<String, dynamic>.from(
    (await dio.patch<dynamic>(
          'places/$id/capture',
          data: command,
          options: Options(headers: {'Idempotency-Key': key}),
        )).data['data']
        as Map,
  );

  Future<Map<String, dynamic>> post(
    String path,
    dynamic body, {
    String? key,
    ProgressCallback? progress,
  }) async => Map<String, dynamic>.from(
    (await dio.post<dynamic>(
          path,
          data: body,
          options: Options(headers: {'Idempotency-Key': ?key}),
          onSendProgress: progress,
        )).data['data']
        as Map,
  );
}

const secureTokens = FlutterSecureStorage();
