import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/models.dart';

void main() {
  test('Fix timestamp uses backend whole-second storage precision', () {
    final f = GpsFix(
      39.5,
      67.6,
      12,
      DateTime.parse('2026-10-17T12:01:02.789Z'),
    ).toJson();
    expect(f['fix_time'], '2026-10-17T12:01:02.000Z');
    expect(f['latitude'], f['measured_latitude']);
    expect(f['longitude'], f['measured_longitude']);
  });
}
