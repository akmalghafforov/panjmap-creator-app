import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/capture/controller.dart';
import 'package:panjmap_capture/capture/models.dart';

import 'controller_test.dart' show MemoryStore, Device;
import 'retry_test.dart' show Server;

void main() {
  test(
    'trimmed payloads, entrance omission, restart and next record reset',
    () async {
      final directory = await Directory.systemTemp.createTemp('capture-fields');
      addTearDown(() => directory.delete(recursive: true));
      final photo = File('${directory.path}/photo.png');
      await photo.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
      for (final type in capturePlaceTypes.keys) {
        final api = Server();
        final store = MemoryStore();
        final c = CaptureController(api, store, Device())
          ..authenticated = true
          ..account = 'account'
          ..config = {'photo_max_kb': 10240, 'photo_max_pixels': 24000000};
        await c.save({
          'file': photo.path,
          'fix': {
            'latitude': 39.5,
            'longitude': 67.6,
            'fix_time': DateTime.now().toUtc().toIso8601String(),
          },
        });
        await c.editField('type', type);
        await c.editField('houseNumber', ' 12А ');
        await c.editField('entranceNumber', ' 2Б ');
        await c.chooseAddress(
          'mahalla',
          'accepted',
          reference: {'id': 'mahalla', 'name': ' Махалля ', 'revision': 1},
        );
        await c.chooseAddress(
          'street',
          'accepted',
          reference: {'id': 'street', 'name': ' Улица ', 'revision': 1},
        );
        await c.submit();
        expect(c.frozen, true);
        expect(c.draft!['place']['house_number'], '12А');
        expect(c.draft!['place']['street'], 'Улица');
        expect(
          c.draft!['entrance'].containsKey('label'),
          type == 'apartment_building',
        );
        if (type == 'apartment_building') {
          expect(c.draft!['entrance']['label'], '2Б');
        }
        final restored = CaptureController(api, store, Device());
        await restored.initialize();
        expect(restored.type, type);
        expect(restored.houseNumber, ' 12А ');
        expect(restored.entranceNumber, ' 2Б ');
        await restored.save({
          ...restored.draft!,
          'photoDone': true,
          'file': '${directory.path}/missing',
        });
        await restored.next();
        expect(restored.type, isNull);
        expect(restored.houseNumber, isEmpty);
        expect(store.value, isNull);
      }
    },
  );
  test('manual entry before GPS, queued edits and restored type', () async {
    final store = MemoryStore();
    final c = CaptureController(Server(), store, Device());
    final edits = [
      c.chooseAddress('mahalla', 'corrected', name: 'Две части '),
      c.chooseAddress('street', 'unknown'),
      c.editField('type', 'apartment_building'),
      c.editField('entranceNumber', '2Б'),
      c.editField('houseNumber', '12А'),
    ];
    await Future.wait(edits);
    expect(store.value!['houseNumber'], '12А');
    expect(store.value!['type'], 'apartment_building');
    expect(store.value!['addressChoices']['mahalla']['name'], 'Две части ');
    expect(store.value!['addressChoices']['street']['status'], 'unknown');
    expect(c.addressPayload({})['mahalla_name'], 'Две части');
  });
  test(
    'all seven types require address, only apartments require entrance',
    () async {
      final c = CaptureController(Server(), MemoryStore(), Device());
      await c.save({'file': 'photo', 'fix': {}, 'houseNumber': '12'});
      await c.chooseAddress(
        'mahalla',
        'accepted',
        reference: {'id': 'mahalla', 'name': 'Махалля', 'revision': 1},
      );
      await c.chooseAddress(
        'street',
        'accepted',
        reference: {'id': 'street', 'name': 'Улица', 'revision': 1},
      );
      expect(capturePlaceTypes.length, 7);
      for (final type in capturePlaceTypes.keys) {
        await c.editField('type', type);
        expect(c.validateFields(), type != 'apartment_building');
      }
      await c.editField('type', 'apartment_building');
      await c.editField('entranceNumber', '2А');
      expect(c.validateFields(), true);
      await c.editField('type', 'shop');
      expect(c.entranceNumber, '2А');
      await c.editField('houseNumber', '   ');
      expect(c.validateFields(), false);
      await c.chooseAddress('mahalla', 'unknown');
      expect(c.validateFields(), false);
      expect(c.fieldErrors.keys, containsAll(['houseNumber', 'mahalla']));
      await c.submit();
      expect(c.frozen, false);
    },
  );
}
