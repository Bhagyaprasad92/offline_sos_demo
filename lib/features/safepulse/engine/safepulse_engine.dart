// lib/features/safepulse/engine/safepulse_engine.dart
import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../services/ai_service.dart';
import '../services/alert_service.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
import '../services/sensor_service.dart';
import '../services/sos_service.dart';
import '../services/warning_service.dart';
import '../../../core/enums.dart';

enum EngineState { idle, monitoring, processingSos }

class SafePulseEngine {
  SafePulseEngine() {
    _initializeServices();
  }

  // Services
  final AIService aiService = AIService();
  final SensorService sensorService = SensorService();
  final LocationService locationService = LocationService();
  final AlertService alertService = AlertService();
  late final WarningService warningService;
  final SosService sosService = SosService();
  final ApiService apiService = ApiService();

  // Streams
  final logStream = StreamController<LogMessage>.broadcast();
  final speedStream = StreamController<double>.broadcast();
  final distractionStream = StreamController<int>.broadcast();
  final stateStream = StreamController<EngineState>.broadcast();
  
  // Custom event for police fallback UI
  final callReturnedStream = StreamController<void>.broadcast();

  bool _isRunning = false;
  DateTime? _lastSosTime;
  
  // System states synced from background isolate
  bool sysLocationOn = true;
  bool sysBatterySaverOn = false;

  bool get _sosLocked =>
      _lastSosTime != null &&
      DateTime.now().difference(_lastSosTime!) < const Duration(minutes: 1);

  void _initializeServices() {
    warningService = WarningService(alertService);

    // Bind loggers
    aiService.onLog = (msg) => log(msg, level: LogLevel.info);
    sensorService.onLog = (msg) => log(msg, level: LogLevel.info);
    locationService.onLog = (msg) => log(msg, level: msg.contains("⚠️") || msg.contains("❌") ? LogLevel.warning : LogLevel.info);
    warningService.onLog = (msg) => log(msg, level: LogLevel.warning);
    sosService.onLog = (msg) => log(msg, level: msg.contains("FAILED") || msg.contains("⚠️") ? LogLevel.warning : LogLevel.info);

    // Bind event streams
    locationService.onSpeedUpdate = (speedMs) {
      speedStream.add(speedMs);
      FlutterBackgroundService().invoke('speed', {'speed': speedMs});
      warningService.handleSpeed(speedMs);
    };

    warningService.onDistractionUpdate = (seconds) {
      distractionStream.add(seconds);
      FlutterBackgroundService().invoke('distraction', {'seconds': seconds});
    };

    sensorService.onRawData = (data) {
      aiService.addData(data);
    };

    aiService.onCrashDetected = (probability) {
      _handleCrash();
    };

    sosService.onCallReturned = () {
      log("Call returned. Escalate to Police if needed.");
      callReturnedStream.add(null);
      FlutterBackgroundService().invoke('callReturned');
    };

    // Init AI
    aiService.initialize();
    alertService.initialize();
  }

  void log(String message, {LogLevel level = LogLevel.info}) {
    logStream.add(LogMessage(message, level: level));
    FlutterBackgroundService().invoke('log', {
      'message': message,
      'level': level.index,
    });
  }

  void _updateState(EngineState state) {
    stateStream.add(state);
    FlutterBackgroundService().invoke('state', {
      'state': state.index,
    });
  }

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    
    _updateState(EngineState.monitoring);
    log("🛡️ AI Dashcam STARTED in Background Isolate.");

    sensorService.start();
    locationService.startSpeedMonitoring();
  }

  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    
    _updateState(EngineState.idle);
    sensorService.stop();
    locationService.stop();
    log("🛑 AI Dashcam STOPPED.");
  }

  Future<void> _handleCrash() async {
    if (_sosLocked) return;
    _lastSosTime = DateTime.now();

    try {
      log("🚀 SOS TRIGGERED AUTONOMOUSLY BY AI!", level: LogLevel.critical);
      _updateState(EngineState.processingSos);

      final position = await locationService.getCurrentPosition();
      bool hasLocation = position != null;
      int? locationAgeSec = hasLocation && locationService.lastValidTime != null 
          ? DateTime.now().difference(locationService.lastValidTime!).inSeconds 
          : null;

      double lat = position?.latitude ?? 0.0;
      double lng = position?.longitude ?? 0.0;

      // Try API first
      log("Sending SOS to Server...", level: LogLevel.critical);
      await apiService.sendSOS(lat, lng, "HIGH", hasLocation: hasLocation, locationAgeSec: locationAgeSec);

      // Try Offline Fallback
      log("Initiating Offline SOS...", level: LogLevel.critical);
      double currentSpeed = locationService.currentSpeedMs ?? 0.0;
      await sosService.triggerOfflineSOS(lat, lng, hasLocation: hasLocation, locationAgeSec: locationAgeSec, speedMs: currentSpeed);
    } finally {
      _updateState(EngineState.idle);
    }
  }

  void dispose() {
    logStream.close();
    speedStream.close();
    distractionStream.close();
    stateStream.close();
    callReturnedStream.close();
    
    aiService.dispose();
    warningService.dispose();
  }
}
