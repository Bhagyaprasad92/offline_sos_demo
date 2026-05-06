// lib/features/safepulse/services/ai_service.dart
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';

class AIService {
  Interpreter? _interpreter;
  final List<List<double>> _sensorBuffer = [];
  
  Function(double probability)? onCrashDetected;
  Function(String message)? onLog;
  
  Future<void> initialize() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/crash_model.tflite');
      onLog?.call("🧠 TFLite AI Crash Model Loaded!");
    } catch (e) {
      onLog?.call("❌ ERROR: Failed to load AI model. Check assets folder.");
    }
  }

  void addData(List<double> data) {
    _sensorBuffer.add(data);

    if (_sensorBuffer.length > 250) {
      _sensorBuffer.removeAt(0); // Keep exactly 5 seconds
    }

    double ax = data[0], ay = data[1], az = data[2];
    double gForce = sqrt(pow(ax, 2) + pow(ay, 2) + pow(az, 2)) / 9.81;

    if (gForce > 3.0 && _sensorBuffer.length == 250) {
      onLog?.call("⚠️ IMPACT: ${gForce.toStringAsFixed(1)} Gs. AI Analyzing...");
      _runAIAnalysis(List.from(_sensorBuffer), gForce);
      _sensorBuffer.clear();
    }
  }

  int _recentSpikeCount = 0;

  void _runAIAnalysis(List<List<double>> windowToAnalyze, double maxGForce) {
    if (_interpreter == null) {
      if (maxGForce > 5.0) {
        _recentSpikeCount++;
        if (_recentSpikeCount >= 2) {
          onLog?.call("⚠️ Basic Threshold Crash Detected! (AI offline)");
          onCrashDetected?.call(1.0);
        } else {
          onLog?.call("⚠️ Spike detected. Awaiting temporal confirmation...");
        }
        Future.delayed(const Duration(seconds: 2), () {
          _recentSpikeCount = 0;
        });
      } else {
        onLog?.call("⚠️ Impact filtered by Basic Threshold (AI offline)");
      }
      return;
    }

    try {
      var input = [windowToAnalyze];
      var output = List.filled(1, 0.0).reshape([1, 1]);

      _interpreter!.run(input, output);
      double crashProbability = output[0][0];

      if (crashProbability > 0.25) {
        onCrashDetected?.call(crashProbability);
      } else {
        onLog?.call("✅ AI Filtered: Just a drop/bump. (${(crashProbability * 100).toStringAsFixed(1)}%)");
      }
    } catch (e) {
      onLog?.call("❌ AI Error: $e. Falling back to basic threshold.");
      if (maxGForce > 5.0) {
        onCrashDetected?.call(1.0);
      }
    }
  }

  void dispose() {
    _interpreter?.close();
  }
}
