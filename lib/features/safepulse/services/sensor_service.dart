// lib/features/safepulse/services/sensor_service.dart
import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';

class SensorService {
  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;

  double _ax = 0, _ay = 0, _az = 0;
  double _gx = 0, _gy = 0, _gz = 0;

  Timer? _sensorTimer;
  Function(List<double> data)? onRawData;
  Function(String message)? onLog;

  int _accelRetryCount = 0;
  int _gyroRetryCount = 0;

  void start() {
    _startAccel();
    _startGyro();

    _sensorTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (onRawData != null) {
        onRawData!([_ax, _ay, _az, _gx, _gy, _gz]);
      }
    });
    
    onLog?.call("Sensors active. Reading at 50Hz.");
  }

  void stop() {
    _sensorTimer?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    onLog?.call("Sensors stopped.");
  }

  void _startAccel() {
    _accelSub?.cancel();
    _accelSub = userAccelerometerEventStream().listen(
      (event) {
        _accelRetryCount = 0;
        _ax = event.x;
        _ay = event.y;
        _az = event.z;
      },
      onError: (_) => _restartAccel(),
      onDone: () => _restartAccel(),
    );
  }

  void _restartAccel() {
    final delay = Duration(milliseconds: min(500 * (_accelRetryCount + 1), 5000));
    onLog?.call("⚠️ Accelerometer error. Retrying in ${delay.inMilliseconds}ms...");
    Future.delayed(delay, () {
      _accelRetryCount++;
      _startAccel();
    });
  }

  void _startGyro() {
    _gyroSub?.cancel();
    _gyroSub = gyroscopeEventStream().listen(
      (event) {
        _gyroRetryCount = 0;
        _gx = event.x;
        _gy = event.y;
        _gz = event.z;
      },
      onError: (_) => _restartGyro(),
      onDone: () => _restartGyro(),
    );
  }

  void _restartGyro() {
    final delay = Duration(milliseconds: min(500 * (_gyroRetryCount + 1), 5000));
    onLog?.call("⚠️ Gyroscope error. Retrying in ${delay.inMilliseconds}ms...");
    Future.delayed(delay, () {
      _gyroRetryCount++;
      _startGyro();
    });
  }
}
