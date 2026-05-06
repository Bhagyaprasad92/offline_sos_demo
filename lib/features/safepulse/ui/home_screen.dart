// lib/features/safepulse/ui/home_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../services/background_service.dart';
import '../engine/safepulse_engine.dart';
import '../../../core/enums.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final List<LogMessage> logs = [];
  LogMessage? lastCriticalLog;
  double currentSpeedRawMs = 0.0;
  int distractionSeconds = 0;
  EngineState engineState = EngineState.idle;
  bool useMs = true;

  late StreamSubscription _logSub;
  late StreamSubscription _speedSub;
  late StreamSubscription _distractionSub;
  late StreamSubscription _stateSub;
  late StreamSubscription _callReturnedSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestAllPermissionsUpfront();
    });

    _loadState();
    _subscribeToStreams();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      engineState = (prefs.getBool("isMonitoring") ?? false) ? EngineState.monitoring : EngineState.idle;
    });
  }

  void _addLocalLog(String msg, LogLevel level) {
    if (!mounted) return;
    setState(() {
      final log = LogMessage(msg, level: level);
      logs.insert(0, log);
      if (level == LogLevel.critical) lastCriticalLog = log;
    });
  }

  void _subscribeToStreams() {
    final service = FlutterBackgroundService();

    _logSub = service.on('log').listen((event) {
      if (mounted && event != null) {
        setState(() {
          final log = LogMessage(
            event['message'] as String,
            level: LogLevel.values[event['level'] as int],
          );
          logs.insert(0, log);
          if (log.level == LogLevel.critical) {
            lastCriticalLog = log;
            HapticFeedback.heavyImpact();
          }
        });
      }
    });

    _speedSub = service.on('speed').listen((event) {
      if (mounted && event != null) {
        setState(() => currentSpeedRawMs = event['speed'] as double);
      }
    });

    _distractionSub = service.on('distraction').listen((event) {
      if (mounted && event != null) {
        setState(() => distractionSeconds = event['seconds'] as int);
      }
    });

    _stateSub = service.on('state').listen((event) {
      if (mounted && event != null) {
        setState(() => engineState = EngineState.values[event['state'] as int]);
      }
    });

    _callReturnedSub = service.on('callReturned').listen((_) {
      if (mounted) _promptPoliceFallback();
    });
  }

  Future<void> _requestAllPermissionsUpfront() async {
    _addLocalLog("🔒 Requesting system permissions...", LogLevel.info);

    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.sms,
      Permission.phone,
      Permission.notification,
    ].request();

    if (statuses[Permission.location]?.isGranted == true) {
      PermissionStatus bgStatus = await Permission.locationAlways.request();
      if (!bgStatus.isGranted) {
        _addLocalLog("⚠️ Background Location denied. App won't work in pocket.", LogLevel.warning);
      }
    }

    if (await Permission.sms.isGranted &&
        await Permission.phone.isGranted &&
        await Permission.location.isGranted) {
      _addLocalLog("✅ All critical permissions secured.", LogLevel.info);
    } else {
      _addLocalLog("❌ WARNING: Missing critical permissions!", LogLevel.critical);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _logSub.cancel();
    _speedSub.cancel();
    _distractionSub.cancel();
    _stateSub.cancel();
    _callReturnedSub.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadState(); // Sync UI with persistent state on resume
      _recheckPermissions();
    }
  }

  Future<void> _recheckPermissions() async {
    if (await Permission.sms.isGranted && 
        await Permission.phone.isGranted && 
        await Permission.location.isGranted) {
      _addLocalLog("✅ System permissions verified on resume.", LogLevel.info);
    } else {
      _addLocalLog("⚠️ Missing critical permissions on resume.", LogLevel.warning);
    }
  }

  void _promptPoliceFallback() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("🚨 Did they answer?"),
          content: const Text(
            "If your emergency contact did not answer, tap below to escalate this to the Police immediately.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("THEY ANSWERED (SAFE)", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                Navigator.of(context).pop();
                _addLocalLog("Escalating to Police (100)...", LogLevel.critical);
                await FlutterPhoneDirectCaller.callNumber("100");
              },
              child: const Text("CALL 100 NOW", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isMonitoring = engineState == EngineState.monitoring;
    bool isProcessing = engineState == EngineState.processingSos;

    final double overspeedLimitMs = 2.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SafePulse Autonomous AI', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black87,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("System Network Status", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Speed Unit:", style: TextStyle(fontWeight: FontWeight.bold)),
                ToggleButtons(
                  borderRadius: BorderRadius.circular(8),
                  isSelected: [!useMs, useMs],
                  onPressed: (int index) {
                    setState(() => useMs = index == 1);
                  },
                  children: const [
                    Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text("km/h")),
                    Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text("m/s (Demo)")),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: currentSpeedRawMs > overspeedLimitMs ? Colors.red.shade100 : Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: currentSpeedRawMs > overspeedLimitMs ? Colors.red : Colors.blue,
                  width: 2,
                ),
              ),
              child: Column(
                children: [
                  const Text("LIVE SPEED", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                  Text(
                    useMs ? "${currentSpeedRawMs.toStringAsFixed(1)} m/s" : "${(currentSpeedRawMs * 3.6).toStringAsFixed(1)} km/h",
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: currentSpeedRawMs > overspeedLimitMs ? Colors.red : Colors.black87,
                    ),
                  ),
                  Text("Limit: ${useMs ? "${overspeedLimitMs.toStringAsFixed(1)} m/s" : "${(overspeedLimitMs * 3.6).toStringAsFixed(1)} km/h"}",
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            if (distractionSeconds > 0)
              Container(
                margin: const EdgeInsets.only(bottom: 20),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange, width: 2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.phone_android, color: Colors.orange, size: 30),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        "Distraction Tracker: ${distractionSeconds}s\n(Screen is ON while moving)",
                        style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),

            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: isMonitoring ? Colors.orange : Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 20),
              ),
              icon: Icon(isMonitoring ? Icons.stop : Icons.memory, color: Colors.white),
              label: Text(
                isMonitoring ? "STOP AI SENSOR MONITORING" : "START AI SENSOR MONITORING",
                style: const TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
              ),
              onPressed: isProcessing ? null : () async {
                final prefs = await SharedPreferences.getInstance();
                final service = FlutterBackgroundService();

                if (isMonitoring) {
                  await prefs.setBool("isMonitoring", false);
                  service.invoke('stopService');
                  setState(() => engineState = EngineState.idle);
                } else {
                  await prefs.setBool("isMonitoring", true);
                  await BackgroundServiceHelper.initializeService();
                  if (!(await service.isRunning())) {
                    await service.startService();
                  }
                  setState(() => engineState = EngineState.monitoring);
                }
              },
            ),
            const SizedBox(height: 20),

            if (isProcessing) const Center(child: CircularProgressIndicator(color: Colors.red)),

            const SizedBox(height: 10),
            const Text("System Logs:", style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),

            if (lastCriticalLog != null)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade100,
                  border: Border.all(color: Colors.red, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.red),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "CRITICAL: ${lastCriticalLog!.text}",
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),

            Expanded(
              child: ListView.builder(
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final log = logs[index];
                  Color textColor = Colors.black87;
                  if (log.level == LogLevel.warning) textColor = Colors.orange;
                  if (log.level == LogLevel.critical) textColor = Colors.red;

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text("[${log.timestamp.toLocal().toString().split(' ')[1].substring(0, 8)}] ${log.text}", 
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: textColor, fontWeight: log.level != LogLevel.info ? FontWeight.bold : FontWeight.normal)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
