import 'dart:math' as math;

const _earthRadius = 6371008.8;
const _radians = math.pi / 180;
typedef _Point = ({double lon, double lat});

_Point? _point(dynamic value) {
  if (value is! List || value.length < 2) return null;
  final lon = value[0], lat = value[1];
  if (lon is! num ||
      lat is! num ||
      !lon.isFinite ||
      !lat.isFinite ||
      lon.abs() > 180 ||
      lat.abs() > 90) {
    return null;
  }
  return (lon: lon.toDouble(), lat: lat.toDouble());
}

double _longitude(double value) => (value + 180) % 360 - 180;
double _angle(_Point a, _Point b) {
  final lat = (b.lat - a.lat) * _radians / 2;
  final lon = (b.lon - a.lon) * _radians / 2;
  final h =
      math.pow(math.sin(lat), 2) +
      math.cos(a.lat * _radians) *
          math.cos(b.lat * _radians) *
          math.pow(math.sin(lon), 2);
  return 2 * math.asin(math.sqrt(h.clamp(0, 1)));
}

double _bearing(_Point a, _Point b) {
  final lon = (b.lon - a.lon) * _radians;
  return math.atan2(
    math.sin(lon) * math.cos(b.lat * _radians),
    math.cos(a.lat * _radians) * math.sin(b.lat * _radians) -
        math.sin(a.lat * _radians) * math.cos(b.lat * _radians) * math.cos(lon),
  );
}

// Shortest distance to the great-circle segment, including its endpoints.
double _segmentDistance(_Point p, _Point a, _Point b) {
  final length = _angle(a, b), distance = _angle(a, p);
  if (length < 1e-15) return distance * _earthRadius;
  final bearing = _bearing(a, p) - _bearing(a, b);
  final along = math.atan2(
    math.sin(distance) * math.cos(bearing),
    math.cos(distance),
  );
  if (along < 0 || along > length) {
    return math.min(distance, _angle(b, p)) * _earthRadius;
  }
  return math
          .asin((math.sin(distance) * math.sin(bearing)).clamp(-1, 1))
          .abs() *
      _earthRadius;
}

// GeoJSON rings use longitude/latitude coordinates. Unwrap around the query
// point so a polygon crossing the date line still has a local interior.
({bool inside, bool boundary}) _contains(List<_Point> ring, _Point p) {
  final longitudes = <double>[ring.first.lon];
  for (final point in ring.skip(1)) {
    longitudes.add(longitudes.last + _longitude(point.lon - longitudes.last));
  }
  final center =
      (longitudes.reduce(math.min) + longitudes.reduce(math.max)) / 2;
  final px = center + _longitude(p.lon - center);
  var inside = false;
  for (var i = 0; i < ring.length - 1; i++) {
    final ax = longitudes[i] - px, ay = ring[i].lat - p.lat;
    final bx = longitudes[i + 1] - px, by = ring[i + 1].lat - p.lat;
    final cross = ax * by - bx * ay;
    if (cross.abs() <= 1e-12 * math.max(1, (bx - ax).abs() + (by - ay).abs()) &&
        math.min(ax, bx) <= 1e-10 &&
        math.max(ax, bx) >= -1e-10 &&
        math.min(ay, by) <= 1e-10 &&
        math.max(ay, by) >= -1e-10) {
      return (inside: true, boundary: true);
    }
    if ((ay > 0) != (by > 0) && ax + (bx - ax) * -ay / (by - ay) > 0) {
      inside = !inside;
    }
  }
  return (inside: inside, boundary: false);
}

/// Distance in metres to a GeoJSON Polygon/MultiPolygon area. Holes are
/// excluded from the area; all ring edges belong to its boundary. Invalid or
/// missing geometry has no distance and sorts after usable geometry.
double? mahallaDistance(dynamic geometry, double latitude, double longitude) {
  final p = _point([longitude, latitude]);
  if (p == null || geometry is! Map) return null;
  final coordinates = geometry['coordinates'];
  if (coordinates is! List) return null;
  final List polygons;
  switch (geometry['type']) {
    case 'Polygon':
      polygons = [coordinates];
    case 'MultiPolygon':
      polygons = coordinates;
    default:
      return null;
  }
  if (polygons.isEmpty) return null;
  var nearest = double.infinity;
  var covered = false;
  for (final polygon in polygons) {
    if (polygon is! List || polygon.isEmpty) return null;
    final rings = <List<_Point>>[];
    for (final raw in polygon) {
      if (raw is! List || raw.length < 4) return null;
      final ring = <_Point>[];
      for (final coordinate in raw) {
        final point = _point(coordinate);
        if (point == null) return null;
        ring.add(point);
      }
      if (ring.first != ring.last || ring.toSet().length < 3) return null;
      // Reject degenerate rings instead of treating them as known distances.
      var area = 0.0;
      for (var i = 0; i < ring.length - 1; i++) {
        area +=
            _longitude(ring[i].lon - ring.first.lon) *
                (ring[i + 1].lat - ring.first.lat) -
            _longitude(ring[i + 1].lon - ring.first.lon) *
                (ring[i].lat - ring.first.lat);
      }
      if (area.abs() < 1e-16) return null;
      rings.add(ring);
    }
    final outer = _contains(rings.first, p);
    var inHole = false;
    var onBoundary = outer.boundary;
    for (final ring in rings.skip(1)) {
      final hole = _contains(ring, p);
      onBoundary = onBoundary || hole.boundary;
      inHole = inHole || hole.inside;
    }
    covered = covered || onBoundary || (outer.inside && !inHole);
    for (final ring in rings) {
      for (var i = 0; i < ring.length - 1; i++) {
        nearest = math.min(nearest, _segmentDistance(p, ring[i], ring[i + 1]));
      }
    }
  }
  return covered ? 0 : nearest;
}
