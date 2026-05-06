// lib/features/safepulse/services/location_service.dart
import 'dart:async';
import 'package:geolocator/geolocator.dart';

class LocationService {
  StreamSubscription<Position>? _positionStreamSub;
  Function(double speedMs)? onSpeedUpdate;
  Function(String message)? onLog;

  Position? _lastValidPosition;
  DateTime? lastValidTime;
  double? get currentSpeedMs => _prevSpeedMs;

  Future<Position?> getCurrentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      onLog?.call("⚠️ GPS lock timed out or failed. Attempting last known position...");
      try {
        final pos = await Geolocator.getLastKnownPosition();
        return pos ?? _lastValidPosition;
      } catch (_) {
        onLog?.call("❌ No last known GPS position available. Using runtime cache if available.");
        return _lastValidPosition;
      }
    }
  }

  double _prevSpeedMs = 0.0;

  void startSpeedMonitoring() {
    onLog?.call("🛰️ GPS Speed Stream Active...");

    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );

    _positionStreamSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      _lastValidPosition = position;
      lastValidTime = DateTime.now();
      double rawMs = position.speed;
      
      double smoothedMs;
      final double overspeedLimitMs = 7.0; // Approx 25 km/h threshold
      if (rawMs > overspeedLimitMs) {
        smoothedMs = rawMs; // Immediate override for sudden spikes
      } else {
        smoothedMs = (_prevSpeedMs * 0.7) + (rawMs * 0.3);
      }
      _prevSpeedMs = smoothedMs;

      if (smoothedMs < 0.2) {
        smoothedMs = 0.0;
      }

      onSpeedUpdate?.call(smoothedMs);
    });
  }

  void stop() {
    _positionStreamSub?.cancel();
  }
}
