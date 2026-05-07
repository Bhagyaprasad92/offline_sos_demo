// lib/features/safepulse/services/api_service.dart
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:synchronized/synchronized.dart';
import 'package:flutter/foundation.dart';

class ApiService {
  final String baseUrl = "http://10.101.100.36:8080";
  static const String _queueKey = 'sos_request_queue';
  final _lock = Lock();

  ApiService();

  void dispose() {
  }

  bool _isFlushing = false;

  Future<void> sendSOS(
    double lat,
    double lng,
    String severity, {
    bool hasLocation = true,
    int? locationAgeSec,
  }) async {
    final eventId = const Uuid().v4();
    final payload = {
      "eventId": eventId,
      "latitude": lat,
      "longitude": lng,
      "locationStatus": hasLocation ? "OK" : "UNAVAILABLE",
      "locationAgeSec": locationAgeSec,
      "severity": severity,
      "timestamp": DateTime.now().toIso8601String(),
    };

    try {
      if (kDebugMode) {
        print("🚀 Sending payload:");
        print(jsonEncode(payload));
      }

      final response = await http
          .post(
            Uri.parse("$baseUrl/api/sos"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 5));

      if (kDebugMode) {
        print("✅ STATUS: ${response.statusCode}");
        print("✅ BODY: ${response.body}");
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        // Success
      } else {
        await _queueRequestLocally(payload, isCritical: true);
      }
    } catch (e) {
      if (kDebugMode) {
        print("❌ HTTP ERROR: $e");
      }
      await _queueRequestLocally(payload, isCritical: true);
    }
  }

  final List<String> _inMemoryQueue = [];
  bool _pendingWrite = false;

  Future<void> _queueRequestLocally(
    Map<String, dynamic> payload, {
    bool isCritical = false,
  }) async {
    await _lock.synchronized(() async {
      _inMemoryQueue.add(jsonEncode(payload));

      if (_inMemoryQueue.length > 20) {
        _inMemoryQueue.removeAt(0);
      }

      if (isCritical) {
        await _saveQueueImmediately();
      } else {
        _scheduleSave();
      }
    });
  }

  Future<void> _saveQueueImmediately() async {
    if (_inMemoryQueue.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    List<String> diskQueue = prefs.getStringList(_queueKey) ?? [];

    diskQueue.addAll(_inMemoryQueue);
    _inMemoryQueue.clear();

    if (diskQueue.length > 50) {
      diskQueue.removeRange(0, diskQueue.length - 50);
    }

    await prefs.setStringList(_queueKey, diskQueue);
  }

  void _scheduleSave() {
    if (_pendingWrite) return;
    _pendingWrite = true;

    Future.delayed(const Duration(seconds: 2), () async {
      await _lock.synchronized(() async {
        await _saveQueueImmediately();
      });
      _pendingWrite = false;
    });
  }

  Future<void> retryQueuedRequests() async {
    if (_isFlushing) return;
    _isFlushing = true;

    try {
      List<String> currentQueue = [];
      await _lock.synchronized(() async {
        final prefs = await SharedPreferences.getInstance();
        currentQueue = prefs.getStringList(_queueKey) ?? [];
      });

      if (currentQueue.isEmpty) return;

      for (String itemStr in currentQueue) {
        bool success = false;
        try {
          final response = await http
              .post(
                Uri.parse("$baseUrl/api/sos"),
                headers: {"Content-Type": "application/json"},
                body: itemStr,
              )
              .timeout(const Duration(seconds: 5));

          if (response.statusCode >= 200 && response.statusCode < 300) {
            success = true;
          }
        } catch (e) {
          // Failure
        }

        if (success) {
          await _lock.synchronized(() async {
            final prefs = await SharedPreferences.getInstance();
            List<String> q = prefs.getStringList(_queueKey) ?? [];
            q.remove(itemStr);
            await prefs.setStringList(_queueKey, q);
          });
        } else {
          await Future.delayed(const Duration(seconds: 2)); // backoff
          break; // Stop on first failure to retain queue order and prevent spam
        }
      }
    } finally {
      _isFlushing = false;
    }
  }
}
