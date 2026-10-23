const capturePlaceTypes = {
  'private_house': 'Дом',
  'apartment_building': 'Этаж',
  'shop': 'Магазин',
  'pharmacy': 'Аптека',
  'other': 'Другое',
};
const placeLabels = {
  'private_house': 'Дом',
  'shop': 'Магазин',
  'pharmacy': 'Аптека',
  'other': 'Другое',
  'apartment_building': 'Многоэтажный жилой дом',
  'bazaar': 'Базар',
  'clinic': 'Клиника',
  'residential_compound': 'Жилой комплекс',
  'building': 'Здание',
};

/// A measured foreground GPS fix, serialized unchanged into an entrance request.
class GpsFix {
  final double latitude, longitude, accuracy;
  final DateTime time;
  const GpsFix(this.latitude, this.longitude, this.accuracy, this.time);
  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'measured_latitude': latitude,
    'measured_longitude': longitude,
    'accuracy_m': accuracy,
    'fix_time': DateTime.fromMillisecondsSinceEpoch(
      time.millisecondsSinceEpoch ~/ 1000 * 1000,
      isUtc: true,
    ).toIso8601String(),
    'position_source': 'gps',
  };
}
