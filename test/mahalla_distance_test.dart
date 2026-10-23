import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/address_lookup.dart';
import 'package:panjmap_capture/capture/mahalla_distance.dart';

import 'address_selector_test.dart' show PickerController, response;

Map<String, dynamic> square(double lon, double lat, {double size = 1}) => {
  'type': 'Polygon',
  'coordinates': [
    [
      [lon, lat],
      [lon + size, lat],
      [lon + size, lat + size],
      [lon, lat + size],
      [lon, lat],
    ],
  ],
};
Map<String, dynamic> row(String id, String name, dynamic geometry) => {
  'id': id,
  'name': name,
  'revision': 1,
  'geometry': geometry,
};
Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'polygon interior, vertices, all edges and shortest boundary distance',
    () {
      final area = square(0, 0);
      expect(mahallaDistance(area, .5, .5), 0);
      for (final point in [
        [0.0, 0.0],
        [0.0, .5],
        [.5, 0.0],
        [1.0, .5],
        [.5, 1.0],
      ]) {
        expect(mahallaDistance(area, point[0], point[1]), 0);
      }
      expect(mahallaDistance(area, .5, 2), closeTo(111191, 10));
      expect(mahallaDistance(area, 0, -1), closeTo(111195, 2));
      expect(mahallaDistance(area, -1, -1), closeTo(157249, 2));
    },
  );

  test(
    'holes exclude their interior but include boundaries; multipolygons',
    () {
      final area = square(0, 0, size: 4);
      (area['coordinates'] as List).add(
        (square(1, 1, size: 2)['coordinates'] as List).single,
      );
      expect(mahallaDistance(area, .5, .5), 0);
      expect(mahallaDistance(area, 2, 2), greaterThan(100000));
      expect(mahallaDistance(area, 1, 2), 0);
      final multi = {
        'type': 'MultiPolygon',
        'coordinates': [area['coordinates'], square(10, 10)['coordinates']],
      };
      expect(mahallaDistance(multi, 10.5, 10.5), 0);
      expect(mahallaDistance(multi, 10.5, 12), closeTo(109333, 100));
    },
  );

  test('invalid geometry and coordinates have unknown distance', () {
    for (final geometry in [
      null,
      {},
      {
        'type': 'Point',
        'coordinates': [0, 0],
      },
      {'type': 'Polygon', 'coordinates': []},
      {
        'type': 'Polygon',
        'coordinates': [
          [
            [0, 0],
            [1, 0],
            [0, 1],
          ],
        ],
      },
      {
        'type': 'Polygon',
        'coordinates': [
          [
            [0, 0],
            [1, 0],
            [2, 0],
            [0, 0],
          ],
        ],
      },
      {
        'type': 'Polygon',
        'coordinates': [
          [
            [0, 0],
            [1, 0],
            [double.nan, 1],
            [0, 0],
          ],
        ],
      },
    ]) {
      expect(mahallaDistance(geometry, 0, 0), isNull);
    }
    expect(mahallaDistance(square(0, 0), 100, 0), isNull);
  });

  test('date line polygon containment stays local', () {
    final area = {
      'type': 'Polygon',
      'coordinates': [
        [
          [179, -1],
          [-179, -1],
          [-179, 1],
          [179, 1],
          [179, -1],
        ],
      ],
    };
    expect(mahallaDistance(area, 0, 180), 0);
    expect(mahallaDistance(area, 0, -179.5), 0);
    expect(mahallaDistance(area, 0, 178), closeTo(111195, 2));
    expect(mahallaDistance(area, 0, 0), greaterThan(19000000));
  });

  test('all pages sorted by area distance, name and ID; local substring and GPS resort', () async {
    final c = PickerController();
    await c.save({
      'fix': {'latitude': .5, 'longitude': .5},
    });
    await c.chooseAddress(
      'mahalla',
      'accepted',
      reference: {'id': 'manual', 'name': 'Сохранённая', 'revision': 9},
    );
    final lookup = AddressLookup(c, 'mahallas');
    addTearDown(lookup.dispose);
    c.requests.single.result.complete({
      'data': [
        row('far', 'Дальняя', square(10, 0)),
        row('missing', 'А без границы', null),
        row('z', 'Внутри', square(0, 0)),
      ],
      'meta': {'page': 1, 'last_page': 2},
    });
    await flush();
    expect(lookup.loading, true);
    expect(lookup.rows, isEmpty);
    expect(c.requests.last.page, 2);
    c.requests.last.result.complete({
      'data': [
        row('near', 'Ближняя', square(2, 0)),
        row('a', 'Внутри', square(0, 0)),
        row('first', 'А внутри', square(0, 0)),
      ],
      'meta': {'current_page': 2, 'last_page': 2},
    });
    await flush();
    expect(lookup.rows.map((r) => r['id']), [
      'first',
      'a',
      'z',
      'near',
      'far',
      'missing',
    ]);
    lookup.search('НУТР');
    expect(lookup.rows.map((r) => r['id']), ['first', 'a', 'z']);
    expect(c.requests.every((r) => r.query.isEmpty), true);
    expect(c.requests.length, 2);
    lookup.search('');
    await c.save({
      ...c.draft!,
      'fix': {'latitude': .5, 'longitude': 10.5},
    });
    c.redraw();
    expect(lookup.rows.first['id'], 'far');
    expect(c.draft!['addressChoices']['mahalla']['id'], 'manual');
    await c.save({...c.draft!, 'fix': null});
    c.redraw();
    expect(lookup.rows.map((r) => r['id']), [
      'missing',
      'first',
      'near',
      'a',
      'z',
      'far',
    ]);
  });

  test(
    'mahalla page failure retries failed page before publishing complete list',
    () async {
      final c = PickerController();
      final lookup = AddressLookup(c, 'mahallas');
      addTearDown(lookup.dispose);
      c.requests.single.result.complete(response('Я', last: 2));
      await flush();
      c.requests.last.result.completeError(StateError('offline'));
      await flush();
      expect(lookup.error, isNotNull);
      expect(lookup.rows, isEmpty);
      final retry = lookup.load();
      expect(c.requests.last.page, 2);
      c.requests.last.result.complete(response('А', page: 2, last: 2));
      await retry;
      expect(lookup.rows.map((r) => r['name']), ['А', 'Я']);
      expect(lookup.error, isNull);
    },
  );

  test('superseded loads and session changes cannot add pages', () async {
    final c = PickerController();
    final lookup = AddressLookup(c, 'mahallas');
    addTearDown(lookup.dispose);
    final fresh = lookup.load(reset: true);
    c.requests.first.result.complete(response('Старый', last: 2));
    await flush();
    expect(c.requests.length, 2);
    c.requests.last.result.complete(response('Новый'));
    await fresh;
    expect(lookup.rows.single['name'], 'Новый');
    final late = lookup.load(reset: true);
    c.authenticated = false;
    c.authenticated = true;
    c.redraw();
    c.requests.last.result.complete(response('Другая сессия', last: 2));
    await late;
    expect(lookup.rows, isEmpty);
    expect(c.requests.length, 3);
  });
}
