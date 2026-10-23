import 'dart:async';

import 'package:flutter/foundation.dart';

import 'controller.dart';
import 'mahalla_distance.dart';

/// A form-scoped lookup. Search text never mutates the saved address choice.
class AddressLookup extends ChangeNotifier {
  final CaptureController controller;
  final String kind;
  late final int session = controller.sessionGeneration;
  AddressLookup(this.controller, this.kind) {
    controller.addListener(_controllerChanged);
    _readFix();
    unawaited(load(reset: true));
  }

  final _rows = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _ordered = [];
  String query = '';
  String? error;
  bool loading = false, more = false, _disposed = false;
  int _generation = 0, _page = 0;
  Timer? _debounce;
  double? _latitude, _longitude;
  bool get active =>
      !_disposed &&
      controller.authenticated &&
      controller.collectionAvailable &&
      controller.sessionGeneration == session;
  bool get isMahalla => kind == 'mahallas';
  List<Map<String, dynamic>> get rows => isMahalla
      ? _ordered
            .where(
              (r) => (r['name'] as String).toLowerCase().contains(
                query.toLowerCase(),
              ),
            )
            .toList()
      : List.unmodifiable(_rows);

  bool _readFix() {
    final fix = controller.draft?['fix'] as Map?;
    final lat = fix?['latitude'], lon = fix?['longitude'];
    final latitude = lat is num && lat.isFinite && lat.abs() <= 90
        ? lat.toDouble()
        : null;
    final longitude = lon is num && lon.isFinite && lon.abs() <= 180
        ? lon.toDouble()
        : null;
    final changed = latitude != _latitude || longitude != _longitude;
    _latitude = latitude;
    _longitude = longitude;
    return changed;
  }

  void _sort() {
    final distances = <Map<String, dynamic>, double?>{
      for (final row in _rows)
        row: _latitude == null || _longitude == null
            ? null
            : mahallaDistance(row['geometry'], _latitude!, _longitude!),
    };
    _ordered = [..._rows]
      ..sort((a, b) {
        final da = distances[a], db = distances[b];
        if (da != null || db != null) {
          if (da == null) return 1;
          if (db == null) return -1;
          final order = da.compareTo(db);
          if (order != 0) return order;
        }
        final name = (a['name'] as String).toLowerCase().compareTo(
          (b['name'] as String).toLowerCase(),
        );
        return name != 0 ? name : '${a['id']}'.compareTo('${b['id']}');
      });
  }

  void _controllerChanged() {
    if (!active) {
      ++_generation;
      _debounce?.cancel();
      _rows.clear();
      _ordered = [];
      loading = more = false;
      error = null;
    } else if (isMahalla && _readFix() && !loading && error == null) {
      _sort();
    }
    notifyListeners();
  }

  void search(String value) {
    if (!active || query == value) return;
    query = value;
    if (isMahalla) {
      notifyListeners();
      return;
    }
    _debounce?.cancel();
    ++_generation; // Invalidate immediately, including during the debounce.
    _rows.clear();
    _page = 0;
    more = false;
    loading = true;
    error = null;
    notifyListeners();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => load(reset: true),
    );
  }

  Future<void> load({bool reset = false}) async {
    if (!active) return;
    final request = ++_generation;
    if (reset) {
      _rows.clear();
      _ordered = [];
      _page = 0;
      more = false;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      do {
        final next = _page + 1;
        final result = await controller.searchAddress(
          kind,
          isMahalla ? '' : query,
          page: next,
        );
        if (!active || request != _generation) return;
        final meta = result['meta'] as Map;
        final page = (meta['page'] ?? meta['current_page']) as num;
        final last = meta['last_page'] as num;
        if (page != next || last < page) {
          throw const FormatException('Invalid pagination');
        }
        final found = (result['data'] as List).map(
          (r) => Map<String, dynamic>.from(r as Map),
        );
        for (final row in found) {
          if (row['name'] is! String ||
              row['id'] == null ||
              row['revision'] == null) {
            continue;
          }
          final index = _rows.indexWhere((r) => r['id'] == row['id']);
          if (index < 0) {
            _rows.add(row);
          } else {
            _rows[index] = row;
          }
        }
        _page = page.toInt();
        more = page < last;
        // Mahallas must be complete before showing the nearest-first list.
      } while (isMahalla && more);
      if (isMahalla) _sort();
      loading = false;
    } catch (_) {
      if (!active || request != _generation) return;
      loading = false;
      error = 'Не удалось загрузить список.';
    }
    notifyListeners();
  }

  void loadMore() {
    if (active && !isMahalla && more && !loading && error == null) {
      unawaited(load());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _debounce?.cancel();
    controller.removeListener(_controllerChanged);
    super.dispose();
  }
}
