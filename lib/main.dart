import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

enum NavigationMode { destination, loop }

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final accessToken = const String.fromEnvironment("ACCESS_TOKEN");
  MapboxOptions.setAccessToken(accessToken);

  runApp(NavigationLanternApp(accessToken: accessToken));
}

class NavigationLanternApp extends StatelessWidget {
  const NavigationLanternApp({super.key, required this.accessToken});

  final String accessToken;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LocationMapPage(accessToken: accessToken),
    );
  }
}

class LocationMapPage extends StatefulWidget {
  const LocationMapPage({super.key, required this.accessToken});

  final String accessToken;

  @override
  State<LocationMapPage> createState() => _LocationMapPageState();
}

class _LocationMapPageState extends State<LocationMapPage> {
  static const double _initialLat = 36.578057;
  static const double _initialLon = 136.648659;
  static const String _routeSourceId = "route-source";
  static const String _routeLayerId = "route-layer";
  static const Set<String> _bleDeviceNames = {"NAV_LANTERN", "ESP32-UART"};
  static const String _bleServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String _bleCharUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
  static const Duration _bleScanDuration = Duration(seconds: 8);
  static const int _servoPhysicalLimitDegrees = 90;
  static const int _servoRearHoldDegrees = 150;
  static const double _pointRemoveDistanceMeters = 25;

  MapboxMap? _mapboxMap;
  geo.Position? _currentPosition;
  StreamSubscription<geo.Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _headingSubscription;
  StreamSubscription<List<ScanResult>>? _bleScanSubscription;
  StreamSubscription<BluetoothAdapterState>? _bleAdapterSubscription;
  StreamSubscription<BluetoothConnectionState>? _bleConnectionSubscription;
  Timer? _bleRescanTimer;

  String? _locationStatus;
  String? _routeStatus;
  String? _bleStatus;
  bool _hasCentered = false;
  bool _styleLoaded = false;
  bool _routeLayerAdded = false;
  bool _routeLoading = false;
  bool _bleConnected = false;
  bool _bleScanning = false;
  bool _bleConnecting = false;
  bool _bleResetting = false;
  int _bleSeenCount = 0;
  String? _bleLastSeen;

  double? _heading;
  double? _distanceToDestination;
  double? _bearingToDestination;
  double? _relativeBearing;
  double? _routeBearing;
  double? _relativeRouteBearing;
  List<List<double>> _routeCoordinates = [];
  final List<Position> _loopWaypoints = [];
  NavigationMode _navigationMode = NavigationMode.destination;
  Position? _destinationPosition;
  GeoJsonSource? _routeSource;
  CircleAnnotationManager? _pointManager;
  final List<CircleAnnotation> _pointAnnotations = [];
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _bleCharacteristic;
  int? _lastSentAngle;
  DateTime? _lastSentAt;
  int _servoTrimDegrees = 0;
  int? _lastServoAimDegrees;

  final ViewportState _initialViewport = CameraViewportState(
    center: Point(coordinates: Position(_initialLon, _initialLat)),
    zoom: 11,
    bearing: 0,
    pitch: 0,
  );

  @override
  void initState() {
    super.initState();
    _initLocation();
    _initHeading();
    _initBle();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _headingSubscription?.cancel();
    _bleScanSubscription?.cancel();
    _bleAdapterSubscription?.cancel();
    _bleConnectionSubscription?.cancel();
    _bleRescanTimer?.cancel();
    FlutterBluePlus.stopScan();
    _bleDevice?.disconnect();
    super.dispose();
  }

  void _onMapCreated(MapboxMap mapboxMap) {
    _mapboxMap = mapboxMap;
    mapboxMap.addInteraction(
      TapInteraction.onMap((context) {
        unawaited(_onMapTap(context));
      }),
    );
    unawaited(_initPointAnnotations(mapboxMap));
    _mapboxMap?.location.updateSettings(
      LocationComponentSettings(enabled: true, pulsingEnabled: true),
    );

    if (_currentPosition != null && !_hasCentered) {
      _centerMapOn(_currentPosition!);
    }

    _applyRouteToMap();
  }

  Future<void> _initPointAnnotations(MapboxMap mapboxMap) async {
    _pointManager = await mapboxMap.annotations.createCircleAnnotationManager();
    await _applyPointsToMap();
  }

  Future<void> _applyPointsToMap() async {
    final manager = _pointManager;
    if (manager == null) {
      return;
    }

    await manager.deleteAll();
    _pointAnnotations.clear();

    final points = _navigationMode == NavigationMode.loop
        ? _loopWaypoints
        : [?_destinationPosition];

    if (points.isEmpty) {
      return;
    }

    final annotations = await manager.createMulti(
      points
          .map(
            (position) => CircleAnnotationOptions(
              geometry: Point(coordinates: position),
              circleColor: const Color(0xFFFF7A1A).toARGB32(),
              circleOpacity: 0.96,
              circleRadius: 8,
              circleStrokeColor: Colors.white.toARGB32(),
              circleStrokeOpacity: 1,
              circleStrokeWidth: 2.5,
            ),
          )
          .toList(),
    );

    _pointAnnotations.addAll(annotations.whereType<CircleAnnotation>());
  }

  void _onStyleLoaded(StyleLoadedEventData data) {
    _styleLoaded = true;
    _applyRouteToMap();
  }

  Future<void> _initLocation() async {
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _locationStatus = "Location services are disabled.";
      });
      return;
    }

    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }

    if (permission == geo.LocationPermission.denied) {
      setState(() {
        _locationStatus = "Location permission denied.";
      });
      return;
    }

    if (permission == geo.LocationPermission.deniedForever) {
      setState(() {
        _locationStatus = "Location permission permanently denied.";
      });
      return;
    }

    setState(() {
      _locationStatus = null;
    });

    _positionSubscription =
        geo.Geolocator.getPositionStream(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
            distanceFilter: 1,
          ),
        ).listen((position) {
          setState(() {
            _currentPosition = position;
          });

          _centerMapOn(position);
          _updateNavigationMetrics();
        });
  }

  void _initHeading() {
    _headingSubscription = FlutterCompass.events?.listen((event) {
      if (!mounted) {
        return;
      }
      setState(() {
        _heading = event.heading;
      });
      _updateNavigationMetrics();
    });
  }

  Future<void> _initBle() async {
    _bleScanSubscription = FlutterBluePlus.scanResults.listen((results) async {
      if (mounted) {
        setState(() {
          _bleSeenCount = results.length;
          _bleLastSeen = _describeBleResult(results);
          if (!_bleConnected && !_bleConnecting) {
            _bleStatus = "BLE: scanning... seen $_bleSeenCount";
          }
        });
      }

      for (final result in results) {
        if (_bleConnected || _bleConnecting || !_matchesBleDevice(result)) {
          continue;
        }

        await FlutterBluePlus.stopScan();
        _bleScanning = false;
        _bleRescanTimer?.cancel();
        _bleDevice = result.device;
        _bleConnecting = true;
        setState(() {
          _bleStatus = "BLE: connecting ${_bleDeviceLabel(result)}...";
        });

        _bleConnectionSubscription?.cancel();
        _bleConnectionSubscription = _bleDevice!.connectionState.listen((
          state,
        ) {
          if (!mounted) {
            return;
          }
          final connected = state == BluetoothConnectionState.connected;
          _bleConnected = connected;
          if (!connected) {
            _bleCharacteristic = null;
          }
          setState(() {
            _bleStatus = "BLE: ${state.name.toLowerCase()}";
          });
          if (!connected) {
            _scheduleBleRescan();
          }
        });

        try {
          await _bleDevice!.connect(timeout: const Duration(seconds: 10));
        } catch (_) {
          _bleConnected = false;
          _bleConnecting = false;
          setState(() {
            _bleStatus = "BLE: connect failed";
          });
          _scheduleBleRescan();
          return;
        }

        final services = await _bleDevice!.discoverServices();
        _bleCharacteristic = _findBleCharacteristic(services);

        if (_bleCharacteristic == null) {
          setState(() {
            _bleStatus = "BLE: characteristic not found";
          });
          _bleConnected = false;
          _bleConnecting = false;
          _scheduleBleRescan();
        } else {
          setState(() {
            _bleStatus = "BLE: ready";
          });
          _bleConnecting = false;
        }

        return;
      }
    });

    _bleAdapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) {
        return;
      }
      if (state == BluetoothAdapterState.on) {
        unawaited(_resetBleAndScan("adapter on"));
        return;
      }
      setState(() {
        _bleStatus = "BLE: ${state.name}";
      });
    });
  }

  Future<void> _startBleScan() async {
    if (_bleScanning || _bleConnected || _bleConnecting) {
      return;
    }

    _bleScanning = true;
    setState(() {
      _bleStatus = "BLE: scanning... seen $_bleSeenCount";
    });

    await FlutterBluePlus.stopScan();
    await FlutterBluePlus.startScan(
      withServices: [Guid(_bleServiceUuid)],
      withNames: _bleDeviceNames.toList(),
      timeout: _bleScanDuration,
    );
    try {
      await FlutterBluePlus.isScanning
          .where((isScanning) => !isScanning)
          .first
          .timeout(_bleScanDuration + const Duration(seconds: 1));
    } catch (_) {
      await FlutterBluePlus.stopScan();
    }
    _bleScanning = false;
    _scheduleBleRescan();
  }

  Future<void> _resetBleAndScan(String reason) async {
    if (_bleResetting) {
      return;
    }
    _bleResetting = true;
    _bleRescanTimer?.cancel();
    try {
      await FlutterBluePlus.stopScan();
      await _bleConnectionSubscription?.cancel();
      final device = _bleDevice;
      _bleDevice = null;
      _bleCharacteristic = null;
      _bleConnected = false;
      _bleConnecting = false;
      _lastSentAngle = null;
      _lastSentAt = null;
      _lastServoAimDegrees = null;
      if (device != null) {
        try {
          await device.disconnect();
        } catch (_) {
          // The device may already be gone; scanning below will recover.
        }
      }
      if (mounted) {
        setState(() {
          _bleStatus = "BLE: reset ($reason)";
        });
      }
    } finally {
      _bleResetting = false;
    }
    await _startBleScan();
  }

  void _scheduleBleRescan() {
    if (_bleConnected) {
      return;
    }
    _bleRescanTimer?.cancel();
    _bleRescanTimer = Timer(const Duration(seconds: 3), _startBleScan);
  }

  bool _matchesBleDevice(ScanResult result) {
    final platformName = result.device.platformName;
    final advName = result.advertisementData.advName;
    final serviceUuids = result.advertisementData.serviceUuids;
    final hasService = serviceUuids.any(
      (uuid) => uuid.str.toLowerCase() == _bleServiceUuid.toLowerCase(),
    );
    return _bleDeviceNames.contains(platformName) ||
        _bleDeviceNames.contains(advName) ||
        hasService;
  }

  String _bleDeviceLabel(ScanResult result) {
    final platformName = result.device.platformName;
    if (platformName.isNotEmpty) {
      return platformName;
    }
    final advName = result.advertisementData.advName;
    if (advName.isNotEmpty) {
      return advName;
    }
    return result.device.remoteId.str;
  }

  String? _describeBleResult(List<ScanResult> results) {
    if (results.isEmpty) {
      return null;
    }
    final preview = results.take(3).map(_bleDeviceLabel).join(", ");
    return results.length > 3 ? "$preview..." : preview;
  }

  BluetoothCharacteristic? _findBleCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() !=
          _bleServiceUuid.toLowerCase()) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid.toString().toLowerCase() ==
            _bleCharUuid.toLowerCase()) {
          return characteristic;
        }
      }
    }
    return null;
  }

  void _centerMapOn(geo.Position position) {
    if (_mapboxMap == null) {
      return;
    }

    if (_hasCentered) {
      return;
    }

    _hasCentered = true;
    _mapboxMap?.setCamera(
      CameraOptions(
        center: Point(
          coordinates: Position(position.longitude, position.latitude),
        ),
        zoom: 15,
        bearing: 0,
        pitch: 0,
      ),
    );
  }

  void _updateNavigationMetrics() {
    final position = _currentPosition;
    if (position == null) {
      return;
    }

    final target = _guidanceTargetPosition();
    final distance = target == null
        ? null
        : geo.Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            target.lat.toDouble(),
            target.lng.toDouble(),
          );

    final bearing = target == null
        ? null
        : _bearingBetween(
            position.latitude,
            position.longitude,
            target.lat.toDouble(),
            target.lng.toDouble(),
          );

    final heading = _heading;
    final routeBearing = _routeCoordinates.length >= 2
        ? _bearingAlongRoute(position)
        : null;
    final relative = heading == null
        ? null
        : bearing == null
        ? null
        : _normalizeBearing(bearing - heading);
    final relativeRoute = heading == null || routeBearing == null
        ? null
        : _normalizeBearing(routeBearing - heading);

    setState(() {
      _distanceToDestination = distance;
      _bearingToDestination = bearing;
      _relativeBearing = relative;
      _routeBearing = routeBearing;
      _relativeRouteBearing = relativeRoute;
    });

    _maybeSendBleAngle();
  }

  Position? _guidanceTargetPosition() {
    if (_navigationMode == NavigationMode.loop && _loopWaypoints.isNotEmpty) {
      return _loopWaypoints.first;
    }
    return _destinationPosition;
  }

  bool get _isAlignmentMode =>
      _destinationPosition == null &&
      _loopWaypoints.isEmpty &&
      _routeCoordinates.isEmpty;

  Future<void> _onMapTap(MapContentGestureContext context) async {
    final tapped = context.point.coordinates;
    if (_navigationMode == NavigationMode.loop) {
      final removeIndex = _nearbyLoopWaypointIndex(tapped);
      if (removeIndex != null) {
        await _removeLoopWaypointAt(removeIndex);
        return;
      }

      if (mounted) {
        setState(() {
          _loopWaypoints.add(tapped);
          _destinationPosition = tapped;
          _routeStatus = _loopWaypoints.length < 2
              ? "もう1点タップで周回ルート"
              : "周回ルート作成中";
          _lastSentAngle = null;
          _lastServoAimDegrees = null;
        });
      }
      await _applyPointsToMap();
      if (_loopWaypoints.length >= 2) {
        await _fetchRouteTo([..._loopWaypoints, _loopWaypoints.first]);
      }
      return;
    }

    if (_destinationPosition != null &&
        _isNearPoint(tapped, _destinationPosition!)) {
      _clearRoute();
      return;
    }

    setState(() {
      _loopWaypoints.clear();
      _destinationPosition = tapped;
      _routeStatus = "ルート作成中";
      _lastSentAngle = null;
      _lastServoAimDegrees = null;
    });
    await _applyPointsToMap();
    await _fetchRouteTo([tapped]);
  }

  int? _nearbyLoopWaypointIndex(Position tapped) {
    for (var i = 0; i < _loopWaypoints.length; i++) {
      if (_isNearPoint(tapped, _loopWaypoints[i])) {
        return i;
      }
    }
    return null;
  }

  bool _isNearPoint(Position a, Position b) {
    return geo.Geolocator.distanceBetween(
          a.lat.toDouble(),
          a.lng.toDouble(),
          b.lat.toDouble(),
          b.lng.toDouble(),
        ) <=
        _pointRemoveDistanceMeters;
  }

  Future<void> _removeLoopWaypointAt(int index) async {
    setState(() {
      _loopWaypoints.removeAt(index);
      _destinationPosition = _loopWaypoints.isEmpty
          ? null
          : _loopWaypoints.first;
      _routeCoordinates = [];
      _routeBearing = null;
      _relativeRouteBearing = null;
      _lastSentAngle = null;
      _lastServoAimDegrees = null;
      _routeStatus = _loopWaypoints.isEmpty
          ? "地点をタップ"
          : _loopWaypoints.length < 2
          ? "もう1点タップで周回ルート"
          : "周回ルート作成中";
    });

    await _applyPointsToMap();
    if (_loopWaypoints.length >= 2) {
      await _fetchRouteTo([..._loopWaypoints, _loopWaypoints.first]);
      return;
    }

    await _applyRouteToMap();
    _updateNavigationMetrics();
  }

  void _setNavigationMode(NavigationMode mode) {
    if (mode == _navigationMode) {
      return;
    }
    setState(() {
      _navigationMode = mode;
      _routeStatus = mode == NavigationMode.destination
          ? "Tap a destination"
          : "Tap loop points";
      _loopWaypoints.clear();
      _destinationPosition = null;
      _routeCoordinates = [];
      _routeBearing = null;
      _relativeRouteBearing = null;
      _lastSentAngle = null;
      _lastServoAimDegrees = null;
    });
    unawaited(_applyRouteToMap());
    unawaited(_applyPointsToMap());
    _updateNavigationMetrics();
  }

  void _clearRoute() {
    setState(() {
      _loopWaypoints.clear();
      _destinationPosition = null;
      _routeCoordinates = [];
      _distanceToDestination = null;
      _bearingToDestination = null;
      _relativeBearing = null;
      _routeBearing = null;
      _relativeRouteBearing = null;
      _routeStatus = _navigationMode == NavigationMode.loop
          ? "Tap loop points"
          : "Tap a destination";
      _lastSentAngle = null;
      _lastServoAimDegrees = null;
    });
    unawaited(_applyRouteToMap());
    unawaited(_applyPointsToMap());
  }

  Future<void> _fetchRouteTo(List<Position> stops) async {
    if (_routeLoading) {
      return;
    }

    final position = await _currentOrFreshPosition();
    if (position == null) {
      setState(() {
        _routeStatus = "Current location unavailable.";
      });
      return;
    }

    if (widget.accessToken.isEmpty) {
      setState(() {
        _routeStatus = "Missing Mapbox access token.";
      });
      return;
    }

    _routeLoading = true;
    setState(() {
      _routeStatus = "Route loading...";
    });

    final coordinates = [
      Position(position.longitude, position.latitude),
      ...stops,
    ].map((p) => "${p.lng},${p.lat}").join(";");

    final path = "/directions/v5/mapbox/walking/$coordinates";

    final uri = Uri.https("api.mapbox.com", path, {
      "geometries": "geojson",
      "overview": "full",
      "access_token": widget.accessToken,
    });

    try {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        final message = _extractRouteErrorMessage(response.body);
        setState(() {
          _routeStatus = message == null
              ? "Route failed (${response.statusCode})."
              : "Route failed (${response.statusCode}): $message";
        });
        return;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = body["routes"] as List<dynamic>?;
      if (routes == null || routes.isEmpty) {
        setState(() {
          _routeStatus = "No routes returned.";
        });
        return;
      }

      final geometry =
          (routes.first as Map<String, dynamic>)["geometry"]
              as Map<String, dynamic>;
      final coords = geometry["coordinates"] as List<dynamic>;
      final route = coords
          .map(
            (point) => <double>[
              ((point as List<dynamic>)[0] as num).toDouble(),
              (point[1] as num).toDouble(),
            ],
          )
          .toList();

      setState(() {
        _routeCoordinates = route;
        _routeStatus = "Route ready";
      });

      _applyRouteToMap();
    } catch (error) {
      setState(() {
        _routeStatus = "Route request failed: $error";
      });
    } finally {
      _routeLoading = false;
      _updateNavigationMetrics();
    }
  }

  Future<geo.Position?> _currentOrFreshPosition() async {
    final cached = _currentPosition;
    if (cached != null) {
      return cached;
    }
    try {
      final ok = await _ensureLocationPermission();
      if (!ok) {
        return null;
      }
      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );
      if (mounted) {
        setState(() {
          _currentPosition = position;
          _locationStatus = null;
        });
      }
      _centerMapOn(position);
      return position;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _locationStatus = "Location services are disabled.";
      });
      return false;
    }

    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }

    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      setState(() {
        _locationStatus = "Location permission denied.";
      });
      return false;
    }
    return true;
  }

  String? _extractRouteErrorMessage(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final message = data["message"];
      return message is String ? message : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _applyRouteToMap() async {
    if (_mapboxMap == null || !_styleLoaded) {
      return;
    }

    final mapboxMap = _mapboxMap!;
    if (_routeCoordinates.isEmpty && !_routeLayerAdded) {
      return;
    }
    if (!_routeLayerAdded) {
      final data = _buildRouteGeoJson();
      final source = GeoJsonSource(id: _routeSourceId, data: data);
      await mapboxMap.style.addSource(source);
      await mapboxMap.style.addLayer(
        LineLayer(
          id: _routeLayerId,
          sourceId: _routeSourceId,
          lineJoin: LineJoin.ROUND,
          lineCap: LineCap.ROUND,
          lineColor: Colors.blueAccent.toARGB32(),
          lineWidth: 6.0,
        ),
      );
      _routeSource = source;
      _routeLayerAdded = true;
      return;
    }

    final source = _routeSource;
    if (source == null) {
      return;
    }
    await source.updateGeoJSON(_buildRouteGeoJson());
  }

  String _buildRouteGeoJson() {
    if (_routeCoordinates.isEmpty) {
      return jsonEncode({"type": "FeatureCollection", "features": []});
    }
    return jsonEncode({
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "geometry": {"type": "LineString", "coordinates": _routeCoordinates},
        },
      ],
    });
  }

  double _bearingBetween(
    double startLat,
    double startLon,
    double endLat,
    double endLon,
  ) {
    final startLatRad = _toRadians(startLat);
    final endLatRad = _toRadians(endLat);
    final deltaLonRad = _toRadians(endLon - startLon);
    final y = sin(deltaLonRad) * cos(endLatRad);
    final x =
        cos(startLatRad) * sin(endLatRad) -
        sin(startLatRad) * cos(endLatRad) * cos(deltaLonRad);
    final bearing = atan2(y, x);
    return _normalizeBearing(_toDegrees(bearing));
  }

  double? _bearingAlongRoute(geo.Position position) {
    if (_routeCoordinates.length < 2) {
      return null;
    }

    var closestIndex = 0;
    var closestDistance = double.infinity;
    for (var i = 0; i < _routeCoordinates.length; i++) {
      final coord = _routeCoordinates[i];
      final distance = geo.Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        coord[1],
        coord[0],
      );
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = i;
      }
    }

    final nextIndex = min(closestIndex + 1, _routeCoordinates.length - 1);
    final prevIndex = max(closestIndex - 1, 0);
    final fromIndex = nextIndex == closestIndex ? prevIndex : closestIndex;
    final toIndex = nextIndex == closestIndex ? closestIndex : nextIndex;

    final from = _routeCoordinates[fromIndex];
    final to = _routeCoordinates[toIndex];

    return _bearingBetween(from[1], from[0], to[1], to[0]);
  }

  double _toRadians(double degrees) => degrees * pi / 180.0;

  double _toDegrees(double radians) => radians * 180.0 / pi;

  double _normalizeBearing(double value) {
    final normalized = value % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  double _toSigned180(double value) {
    final normalized = _normalizeBearing(value);
    return normalized > 180 ? normalized - 360 : normalized;
  }

  int? _rawNavigationAngle() {
    if (_isAlignmentMode) {
      return 0;
    }

    final angle = _relativeRouteBearing ?? _relativeBearing;
    if (angle == null) {
      return null;
    }

    final signed = _toSigned180(angle);
    return signed.round();
  }

  int _normalizeServoAim(num angle) {
    return angle.round().clamp(
      -_servoPhysicalLimitDegrees,
      _servoPhysicalLimitDegrees,
    );
  }

  int _servoPhysicalDegrees(int aimDegrees) {
    return (90 + aimDegrees).clamp(0, 180);
  }

  int _servoAimWithTrim(int rawAngle, {bool remember = false}) {
    final adjustedAngle = rawAngle + _servoTrimDegrees;
    final aim = _stableServoAim(adjustedAngle);
    if (remember) {
      _lastServoAimDegrees = aim;
    }
    return aim;
  }

  int _stableServoAim(num angle) {
    final rounded = angle.round();
    if (rounded.abs() >= _servoRearHoldDegrees) {
      final previousAim = _lastServoAimDegrees;
      if (previousAim != null && previousAim != 0) {
        return previousAim.isNegative
            ? -_servoPhysicalLimitDegrees
            : _servoPhysicalLimitDegrees;
      }
      return rounded.isNegative
          ? -_servoPhysicalLimitDegrees
          : _servoPhysicalLimitDegrees;
    }
    return _normalizeServoAim(rounded);
  }

  int _servoPayloadForPhysicalDegrees(int physicalDegrees) {
    return ((90 - physicalDegrees) * 2).clamp(-180, 180);
  }

  int _servoPayloadForRawAngle(int rawAngle) {
    final physicalDegrees = _servoPhysicalDegrees(
      _servoAimWithTrim(rawAngle, remember: true),
    );
    return _servoPayloadForPhysicalDegrees(physicalDegrees);
  }

  void _maybeSendBleAngle({bool force = false}) {
    if (_bleCharacteristic == null || !_bleConnected) {
      return;
    }

    if (_isAlignmentMode && !force) {
      return;
    }

    final rawAngle = _rawNavigationAngle();
    if (rawAngle == null) {
      return;
    }

    final intAngle = _servoPayloadForRawAngle(rawAngle);
    final last = _lastSentAngle;
    final now = DateTime.now();
    final lastSentAt = _lastSentAt;
    final elapsedMs = lastSentAt == null
        ? 9999
        : now.difference(lastSentAt).inMilliseconds;

    if (!force &&
        last != null &&
        (intAngle - last).abs() < 2 &&
        elapsedMs < 500) {
      return;
    }

    _lastSentAngle = intAngle;
    _lastSentAt = now;
    _sendBleAngle(intAngle);
  }

  void _alignServoToCurrentArrow() {
    if (!_isAlignmentMode) {
      setState(() {
        _routeStatus = "Clear the route before aligning.";
      });
      return;
    }

    final rawAngle = _rawNavigationAngle();
    if (rawAngle == null) {
      setState(() {
        _routeStatus = "No arrow angle to align yet.";
      });
      return;
    }
    setState(() {
      _lastSentAngle = null;
      _routeStatus = "Lantern alignment registered.";
    });
    _maybeSendBleAngle(force: true);
  }

  void _nudgeServoTrim(int deltaDegrees) {
    if (!_isAlignmentMode) {
      setState(() {
        _routeStatus = "Clear the route before trimming.";
      });
      return;
    }

    setState(() {
      _servoTrimDegrees = _normalizeServoAim(_servoTrimDegrees + deltaDegrees);
      _lastSentAngle = null;
      _routeStatus =
          "Servo trim: ${_servoTrimDegrees > 0 ? '+' : ''}"
          "$_servoTrimDegrees deg";
    });
    _maybeSendBleAngle(force: true);
  }

  Future<void> _sendBleAngle(int angle) async {
    final characteristic = _bleCharacteristic;
    if (characteristic == null || !_bleConnected) {
      return;
    }

    final payload = "$angle\n";
    await characteristic.write(payload.codeUnits, withoutResponse: true);
  }

  String _formatDistance(double? meters) {
    if (meters == null) {
      return "--";
    }
    if (meters >= 1000) {
      final km = meters / 1000;
      return "${km.toStringAsFixed(1)} km";
    }
    return "${meters.toStringAsFixed(0)} m";
  }

  String get _bleChipLabel {
    if (_bleConnected) {
      return "BLE ready";
    }
    if (_bleConnecting) {
      return "BLE link";
    }
    if (_bleScanning) {
      if (_bleLastSeen != null) {
        return "BLE $_bleSeenCount seen";
      }
      return "BLE scan";
    }
    if (_bleStatus?.contains("reset") ?? false) {
      return "BLE reset";
    }
    return "BLE off";
  }

  String get _servoChipLabel {
    final rawNavigationAngle = _rawNavigationAngle();
    if (rawNavigationAngle == null) {
      return "Servo --";
    }
    final physicalDegrees = _servoPhysicalDegrees(
      _servoAimWithTrim(rawNavigationAngle),
    );
    return "Servo $physicalDegrees°";
  }

  String get _hintText {
    if (_currentPosition == null && _locationStatus != null) {
      return _locationStatus!;
    }
    if (_routeLoading) {
      return "ルート作成中";
    }
    if (_routeStatus != null && _routeStatus != "Route ready") {
      return _routeStatus!;
    }
    if (_destinationPosition != null || _loopWaypoints.isNotEmpty) {
      final distance = _distanceToDestination == null
          ? null
          : "あと ${_formatDistance(_distanceToDestination)}";
      return [?distance, "地点を再タップで削除"].join("  ");
    }
    return _navigationMode == NavigationMode.destination
        ? "地図をタップして目的地へ"
        : "地図をタップして周回地点を追加";
  }

  Widget _guidanceChip(double angleDegrees) {
    final absoluteBearing = _routeBearing ?? _bearingToDestination;
    return Semantics(
      label: absoluteBearing == null
          ? "Guidance arrow"
          : "Guidance arrow ${absoluteBearing.round()} degrees",
      child: GestureDetector(
        onTap: _isAlignmentMode ? _alignServoToCurrentArrow : null,
        onHorizontalDragEnd: _isAlignmentMode
            ? (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity.abs() < 80) {
                  return;
                }
                _nudgeServoTrim(velocity > 0 ? 5 : -5);
              }
            : null,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.76),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Center(
            child: Transform.rotate(
              angle: _toRadians(angleDegrees),
              child: const Icon(
                Icons.navigation,
                color: Colors.white,
                size: 30,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusChip(String label) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 132),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }

  Widget _hintChip(String text) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 330),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeToggle() {
    return Center(
      child: Container(
        width: 224,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Row(
          children: [
            _modeToggleItem(NavigationMode.destination, "目的地"),
            _modeToggleItem(NavigationMode.loop, "周回"),
          ],
        ),
      ),
    );
  }

  Widget _modeToggleItem(NavigationMode mode, String label) {
    final selected = _navigationMode == mode;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _setNavigationMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mapWidget = MapWidget(
      key: const ValueKey("mapWidget"),
      onMapCreated: _onMapCreated,
      onStyleLoadedListener: _onStyleLoaded,
      viewport: _initialViewport,
    );

    final guidanceAngle = _relativeRouteBearing ?? _relativeBearing ?? 0;

    return Scaffold(
      body: Stack(
        children: [
          mapWidget,
          Positioned.fill(
            child: SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    child: _guidanceChip(guidanceAngle.toDouble()),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _statusChip(_bleChipLabel),
                        const SizedBox(height: 6),
                        _statusChip(_servoChipLabel),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 66,
                    child: _hintChip(_hintText),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _modeToggle(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
