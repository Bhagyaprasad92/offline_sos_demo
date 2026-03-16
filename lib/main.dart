import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:telephony_fix/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

void main() {
  runApp(
    const MaterialApp(
      home: AutonomousSOSScreen(),
      debugShowCheckedModeBanner: false,
    ),
  );
}

class AutonomousSOSScreen extends StatefulWidget {
  const AutonomousSOSScreen({super.key});

  @override
  State<AutonomousSOSScreen> createState() => _AutonomousSOSScreenState();
}

class _AutonomousSOSScreenState extends State<AutonomousSOSScreen>
    with WidgetsBindingObserver {
  // --- 1. SOS Variables ---
  final Telephony telephony = Telephony.instance;
  List<String> logs = [];
  bool isProcessing = false;
  bool _isAwaitingCallReturn = false;
  final List<String> emergencyContacts = [
    "+919963093026",
    "+916305259511",
    "+919381363374",
    "+918143837005",
    "+916305560939",
    "+919391479869",
    "+919435608337",
  ];
  // --- 2. AI Sensor Variables ---
  Interpreter? _interpreter;
  bool isMonitoring = false;
  Timer? _sensorTimer;
  List<List<double>> sensorBuffer = []; // The 5-second rolling memory
  double ax = 0, ay = 0, az = 0;
  double gx = 0, gy = 0, gz = 0;
  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAIModel();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopMonitoring();
    _interpreter?.close();
    super.dispose();
  }

  void addLog(String message) {
    if (mounted) {
      setState(() {
        logs.insert(
          0,
          "[${DateTime.now().toLocal().toString().split(' ')[1].substring(0, 8)}] $message",
        );
      });
    }
  }

  // ==========================================
  // 🧠 PHASE 1: AI CRASH DETECTION
  // ==========================================
  Future<void> _loadAIModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/crash_model.tflite');
      addLog("🧠 TFLite AI Crash Model Loaded!");
    } catch (e) {
      addLog("❌ ERROR: Failed to load AI model. Check assets folder.");
    }
  }

  void _toggleMonitoring() {
    if (isMonitoring) {
      _stopMonitoring();
    } else {
      _startMonitoring();
    }
  }

  void _startMonitoring() {
    setState(() => isMonitoring = true);
    addLog("🛡️ AI Dashcam STARTED. Listening at 50Hz...");
    sensorBuffer.clear();

    _accelSub = userAccelerometerEventStream().listen((event) {
      ax = event.x;
      ay = event.y;
      az = event.z;
    });
    _gyroSub = gyroscopeEventStream().listen((event) {
      gx = event.x;
      gy = event.y;
      gz = event.z;
    });

    _sensorTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      sensorBuffer.add([ax, ay, az, gx, gy, gz]);

      if (sensorBuffer.length > 250) {
        sensorBuffer.removeAt(0); // Keep exactly 5 seconds of memory
      }

      // The Heuristic Gate: Detect 3.0+ G-Force (Lowered for safe mattress testing)
      double gForce = sqrt(pow(ax, 2) + pow(ay, 2) + pow(az, 2)) / 9.81;

      if (gForce > 3.0 && sensorBuffer.length == 250) {
        addLog("⚠️ IMPACT: ${gForce.toStringAsFixed(1)} Gs. AI Analyzing...");
        _runAIAnalysis(List.from(sensorBuffer));
        sensorBuffer.clear();
      }
    });
  }

  void _stopMonitoring() {
    setState(() => isMonitoring = false);
    _sensorTimer?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    addLog("🛑 AI Dashcam STOPPED.");
  }

  void _runAIAnalysis(List<List<double>> windowToAnalyze) {
    if (_interpreter == null) return;

    try {
      var input = [windowToAnalyze];
      var output = List.filled(1, 0.0).reshape([1, 1]);

      _interpreter!.run(input, output);
      double crashProbability = output[0][0];

      if (crashProbability > 0.25) {
        addLog(
          "🚨 AI CONFIRMED CRASH! (${(crashProbability * 100).toStringAsFixed(1)}%)",
        );
        _stopMonitoring(); // Stop sensors so they don't trigger repeatedly

        // 🚀 THE MAGIC: AI is pressing the button for the user!
        triggerSOS();
      } else {
        addLog(
          "✅ AI Filtered: Just a drop/bump. (${(crashProbability * 100).toStringAsFixed(1)}%)",
        );
      }
    } catch (e) {
      addLog("❌ AI Error: $e");
    }
  }

  // ==========================================
  // 🚀 PHASE 2: AUTOMATED SOS EXECUTION
  // ==========================================
  Future<void> requestPermissions() async {
    await [Permission.location, Permission.sms, Permission.phone].request();
    addLog("Permissions verified.");
  }

  Future<void> triggerSOS() async {
    setState(() => isProcessing = true);
    addLog("🚀 SOS TRIGGERED AUTONOMOUSLY BY AI!");

    await requestPermissions();

    try {
      final connectivityResult = await (Connectivity().checkConnectivity());
      bool hasInternet =
          connectivityResult.contains(ConnectivityResult.mobile) ||
          connectivityResult.contains(ConnectivityResult.wifi);

      addLog(hasInternet ? "Internet: ONLINE" : "Internet: OFFLINE");
      addLog("Locking GPS coordinates...");

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      String payload =
          "SOS EMERGENCY! AI Detected Severe Crash. Location: https://maps.google.com/?q=${position.latitude},${position.longitude}";

      if (hasInternet) {
        addLog("Routing payload via Firebase (Simulated).");
        setState(() => isProcessing = false);
      } else {
        addLog(
          "Broadcasting offline SMS to ${emergencyContacts.length} contacts...",
        );

        int completedSmsCount = 0;
        Set<String> processedNumbers = {};

        for (String number in emergencyContacts) {
          telephony.sendSms(
            to: number,
            message: payload,
            statusListener: (SendStatus status) {
              if (processedNumbers.contains(number)) return;
              if (status == SendStatus.SENT) {
                addLog("SUCCESS: SMS to $number.");
                processedNumbers.add(number);
                completedSmsCount++;
              } else if (status != SendStatus.DELIVERED) {
                addLog("FAILED: SMS to $number.");
                processedNumbers.add(number);
                completedSmsCount++;
              }

              if (completedSmsCount == emergencyContacts.length && mounted) {
                setState(() => isProcessing = false);
              }
            },
          );
          await Future.delayed(const Duration(milliseconds: 300));
        }

        if (emergencyContacts.isNotEmpty) {
          String primaryContact = emergencyContacts.first;
          addLog("Initiating Fallback Call to $primaryContact...");

          _isAwaitingCallReturn = true;
          bool? callSuccess = await FlutterPhoneDirectCaller.callNumber(
            primaryContact,
          );

          if (callSuccess != true) {
            addLog("FAILED: Could not initiate call.");
            _isAwaitingCallReturn = false;
          }
        }
      }
    } catch (e) {
      addLog("ERROR: ${e.toString()}");
      if (mounted) setState(() => isProcessing = false);
    }
  }

  // ==========================================
  // 📞 PHASE 3: APP LIFECYCLE (POLICE FALLBACK)
  // ==========================================
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAwaitingCallReturn) {
      _isAwaitingCallReturn = false;
      _promptPoliceFallback();
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
              child: const Text(
                "THEY ANSWERED (SAFE)",
                style: TextStyle(color: Colors.grey),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                Navigator.of(context).pop();
                addLog("Escalating to Police (100)...");
                await FlutterPhoneDirectCaller.callNumber("100");
              },
              child: const Text(
                "CALL 100 NOW",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================
  // 📱 USER INTERFACE
  // ==========================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SafePulse Autonomous AI',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black87,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "System Network Status",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),

            // 🚀 Replaced manual button with AI Toggle
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: isMonitoring ? Colors.orange : Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 20),
              ),
              icon: Icon(
                isMonitoring ? Icons.stop : Icons.memory,
                color: Colors.white,
              ),
              label: Text(
                isMonitoring
                    ? "STOP AI SENSOR MONITORING"
                    : "START AI SENSOR MONITORING",
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: isProcessing ? null : _toggleMonitoring,
            ),
            const SizedBox(height: 20),

            if (isProcessing)
              const Center(child: CircularProgressIndicator(color: Colors.red)),

            const SizedBox(height: 10),
            const Text(
              "System Logs:",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Divider(),

            Expanded(
              child: ListView.builder(
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text(
                      logs[index],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
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
