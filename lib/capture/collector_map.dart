import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'controller.dart';

/// Display-only location: never writes coordinates to the capture draft.
class CollectorMap extends StatefulWidget {
  final CaptureController controller;
  final TileProvider? tileProvider;
  const CollectorMap({super.key, required this.controller, this.tileProvider});

  @override
  State<CollectorMap> createState() => _CollectorMapState();
}

class _CollectorMapState extends State<CollectorMap> {
  static const panjakent = LatLng(39.495, 67.61);
  final map = MapController();
  bool tileFailed = false;
  int revision = -1;
  CaptureController get c => widget.controller;
  LatLng get center => c.mapPosition == null
      ? panjakent
      : LatLng(c.mapPosition!.latitude, c.mapPosition!.longitude);

  @override
  void didUpdateWidget(covariant CollectorMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (revision != c.mapRevision) {
      revision = c.mapRevision;
      map.move(center, c.mapPosition == null ? 13 : 16);
    }
  }

  @override
  void dispose() {
    map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: Stack(
          children: [
            FlutterMap(
              mapController: map,
              options: MapOptions(
                initialCenter: center,
                initialZoom: c.mapPosition == null ? 13 : 16,
                onMapReady: () => revision = c.mapRevision,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'tj.panjmap.panjmap_capture',
                  tileProvider: widget.tileProvider,
                  errorTileCallback: (_, _, _) {
                    if (!tileFailed) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) setState(() => tileFailed = true);
                      });
                    }
                  },
                ),
                if (c.mapPosition != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: center,
                        width: 48,
                        height: 48,
                        child: const Icon(
                          Icons.location_pin,
                          size: 48,
                          color: Colors.blue,
                          semanticLabel: 'Текущее местоположение',
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                shape: const CircleBorder(),
                child: IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Обновить местоположение',
                  onPressed: c.mapLoading
                      ? null
                      : () => c.refreshMapLocation(requestPermission: true),
                  icon: const Icon(Icons.my_location),
                ),
              ),
            ),
            const Positioned(
              bottom: 0,
              left: 0,
              right: 88,
              child: ColoredBox(
                color: Colors.white,
                child: Text(
                  '© OpenStreetMap contributors',
                  style: TextStyle(color: Colors.black, fontSize: 12),
                ),
              ),
            ),
            if (c.mapLoading)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(),
              ),
            if (tileFailed)
              const Positioned(
                top: 4,
                left: 4,
                right: 60,
                child: ColoredBox(
                  color: Colors.white,
                  child: Text(
                    'Карта не загрузилась. Проверьте интернет.',
                    style: TextStyle(color: Colors.black),
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class MapLocationNotice extends StatelessWidget {
  final CaptureController controller;
  const MapLocationNotice({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => controller.mapMessage == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(controller.mapMessage!),
              Wrap(
                children: [
                  TextButton(
                    onPressed: () =>
                        controller.refreshMapLocation(requestPermission: true),
                    child: const Text('Повторить GPS'),
                  ),
                  TextButton(
                    onPressed: Geolocator.openAppSettings,
                    child: const Text('Настройки приложения'),
                  ),
                  TextButton(
                    onPressed: Geolocator.openLocationSettings,
                    child: const Text('Настройки геолокации'),
                  ),
                ],
              ),
            ],
          ),
        );
}
