import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:screen_state/screen_state.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import 'package:torch_light/torch_light.dart';
import 'package:volume_controller/volume_controller.dart';
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
  final List<String> emergencyContacts = ["+919963093026", "+916305259511"];
  // "+919381363374",
  // "+918143837005",
  // "+916305560939",
  // "+919391479869",
  // "+919435608337",
  // --- 2. AI Sensor Variables ---
  Interpreter? _interpreter;
  bool isMonitoring = false;
  Timer? _sensorTimer;
  List<List<double>> sensorBuffer = []; // The 5-second rolling memory
  double ax = 0, ay = 0, az = 0;
  double gx = 0, gy = 0, gz = 0;
  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;

  // --- 3. Speed & Voice Warning Variables ---
  final FlutterTts flutterTts = FlutterTts();
  StreamSubscription<Position>? _positionStreamSub;

  bool useMs = true; // TOGGLE: true = m/s (Demo), false = km/h (Real)
  double currentSpeedRawMs = 0.0; // Store pure hardware speed

  // HARDWARE DEMO THRESHOLDS (in meters/second)
  final double overspeedLimitMs = 2.0; // ~7.2 km/h (Brisk Walk/Jog)
  final double distractionLimitMs = 1.0; // ~3.6 km/h (Slow Walk)

  DateTime? lastWarningTime;

  // --- 4. Distracted Driving Variables ---
  final Screen _screen = Screen();
  StreamSubscription<ScreenStateEvent>? _screenStateSub;
  bool isScreenOn = true; // Assume true when app opens
  Timer? distractionTimer;
  int distractionSeconds = 0;
  final int distractionDemoThreshold = 15; // Trigger at 15s for the demo

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAIModel();
    _initTTS(); // <-- ADD THIS
    _initScreenState(); // <-- Add this
    _startSpeedMonitoring(); // <-- ADD THIS
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopMonitoring();
    _stopDistractionTimer(); // <-- Add this
    _interpreter?.close();
    _positionStreamSub?.cancel(); // <-- ADD THIS
    _screenStateSub?.cancel(); // <-- Add this
    super.dispose();
  }

  void _initScreenState() {
    try {
      _screenStateSub = _screen.screenStateStream.listen((
        ScreenStateEvent event,
      ) {
        if (event == ScreenStateEvent.SCREEN_ON ||
            event == ScreenStateEvent.SCREEN_UNLOCKED) {
          isScreenOn = true;
          addLog("📱 System: Screen Turned ON");
        } else if (event == ScreenStateEvent.SCREEN_OFF) {
          isScreenOn = false;
          addLog("📵 System: Screen Locked (Safe)");
          _stopDistractionTimer(); // Stop warning them, they listened!
        }
      });
    } catch (e) {
      addLog("Screen State Error: $e");
    }
  }

  void _startDistractionTimer() {
    addLog("👀 Distraction tracker started (Speeding + Screen ON)");
    distractionSeconds = 0;

    distractionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() => distractionSeconds++);
      }

      if (distractionSeconds == distractionDemoThreshold) {
        flutterTts.speak(
          "Warning! Distracted driving detected. Please put your phone away.",
        );
        addLog("🚨 DISTRACTED DRIVING WARNING ISSUED");
      } else if (distractionSeconds > distractionDemoThreshold &&
          distractionSeconds % 10 == 0) {
        flutterTts.speak("Please lock your screen immediately.");
      }
    });
  }

  void _stopDistractionTimer() {
    if (distractionTimer != null && distractionTimer!.isActive) {
      distractionTimer!.cancel();
      if (mounted) {
        setState(() => distractionSeconds = 0);
      }
      addLog("✅ Distraction averted.");
    }
  }

  Future<void> _initTTS() async {
    await flutterTts.setLanguage("en-IN");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    // CRITICAL: Force the code to wait until the voice stops speaking
    await flutterTts.awaitSpeakCompletion(true);
  }

  void _startSpeedMonitoring() async {
    await Permission.location.request();
    addLog("🛰️ GPS Speed Stream Active...");

    // 1. OPTIMIZE GPS: Re-add a small distance filter. 
    // Setting this to 0 breaks speed math on some Android hardware!
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1, // Send update every 1 meter of movement
    );

    _positionStreamSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      double rawMs = position.speed; // Natively in m/s

      // 2. THE NOISE GATE: Lowered to 0.2 m/s to easily catch walking
      // while still blocking "phantom" jitter when the phone is on a desk.
      if (rawMs < 0.2) {
        rawMs = 0.0;
      }

      if (mounted) {
        setState(() {
          currentSpeedRawMs = rawMs;
        });
      }

      // 1. OVERSPEED LOGIC (Trigger at 2.0 m/s)
      if (rawMs > overspeedLimitMs) {
        _triggerVoiceWarning();
      }

      // 2. DISTRACTED DRIVING LOGIC (Trigger moving > 1.0 m/s with screen ON)
      if (rawMs > distractionLimitMs && isScreenOn) {
        if (distractionTimer == null || !distractionTimer!.isActive) {
          _startDistractionTimer();
        }
      } else if (rawMs <= distractionLimitMs) {
        _stopDistractionTimer();
      }
    });
  }

  Future<void> _triggerHardwareAlert() async {
    // 1. Vibrate (Pattern: Wait 0ms, Vibrate 500ms, Wait 500ms, Vibrate 500ms...)
    try {
      bool? hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(pattern: [0, 500, 500, 500, 500, 500]);
      }
    } catch (e) {
      addLog("Vibration error: $e");
    }

    // 2. Flashlight Blink (3 times)
    try {
      bool hasTorch = await TorchLight.isTorchAvailable();
      if (hasTorch) {
        for (int i = 0; i < 3; i++) {
          await TorchLight.enableTorch();
          await Future.delayed(const Duration(milliseconds: 300));
          await TorchLight.disableTorch();
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
    } catch (e) {
      addLog("Torch error: $e");
    }
  }

  void _triggerVoiceWarning() async {
    // Increased cooldown to 15 seconds because speaking 3 times takes about 10 seconds
    if (lastWarningTime == null ||
        DateTime.now().difference(lastWarningTime!) >
            const Duration(seconds: 15)) {
      lastWarningTime = DateTime.now();

      double displaySpeed = useMs ? currentSpeedRawMs : currentSpeedRawMs * 3.6;
      String unit = useMs ? "m/s" : "km/h";

      addLog(
        "⚠️ SPEED LIMIT EXCEEDED: ${displaySpeed.toStringAsFixed(1)} $unit",
      );

      // 🔥 1. FORCE SYSTEM VOLUME TO MAX (100%)
      try {
        // Set to 1.0 (max) and hide the native Android volume slider popup
        VolumeController.instance.showSystemUI = false;
        VolumeController.instance.setVolume(1.0);
        addLog("🔊 System media volume forced to MAXIMUM.");
      } catch (e) {
        addLog("Volume override error: $e");
      }

      // 🔥 2. Fire hardware alerts concurrently (Do NOT use await here)
      _triggerHardwareAlert();

      // 🗣️ 3. Speak exactly 3 times sequentially
      for (int i = 0; i < 3; i++) {
        await flutterTts.speak(
          "Warning! Reduce your speed. You are moving too fast.",
        );
        // Small 500ms gap between sentences so they don't sound rushed
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
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

        Set<String> processedNumbers = {};

        // 1. Dispatch SMS asynchronously
        for (String number in emergencyContacts) {
          telephony.sendSms(
            to: number,
            message: payload,
            statusListener: (SendStatus status) {
              if (processedNumbers.contains(number)) return;
              if (status == SendStatus.SENT) {
                addLog("SUCCESS: SMS to $number.");
                processedNumbers.add(number);
              } else if (status != SendStatus.DELIVERED) {
                addLog("FAILED: SMS to $number.");
                processedNumbers.add(number);
              }
              // Removed the UI loader logic from here to prevent background locking
            },
          );
          await Future.delayed(const Duration(milliseconds: 300));
        }

        // 2. Stop the loader BEFORE launching the native phone dialer
        if (mounted) {
          setState(() => isProcessing = false);
        }

        // 3. Launch the call
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

            // --- LIVE SPEEDOMETER UI ---
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Speed Unit:",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                ToggleButtons(
                  borderRadius: BorderRadius.circular(8),
                  isSelected: [!useMs, useMs],
                  onPressed: (int index) {
                    setState(() {
                      useMs = index == 1;
                    });
                  },
                  children: const [
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text("km/h"),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text("m/s (Demo)"),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:
                    currentSpeedRawMs > overspeedLimitMs
                        ? Colors.red.shade100
                        : Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      currentSpeedRawMs > overspeedLimitMs
                          ? Colors.red
                          : Colors.blue,
                  width: 2,
                ),
              ),
              child: Column(
                children: [
                  const Text(
                    "LIVE SPEED",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.black54,
                    ),
                  ),
                  Text(
                    useMs
                        ? "${currentSpeedRawMs.toStringAsFixed(1)} m/s"
                        : "${(currentSpeedRawMs * 3.6).toStringAsFixed(1)} km/h",
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color:
                          currentSpeedRawMs > overspeedLimitMs
                              ? Colors.red
                              : Colors.black87,
                    ),
                  ),
                  Text(
                    "Limit: ${useMs ? overspeedLimitMs.toStringAsFixed(1) + " m/s" : (overspeedLimitMs * 3.6).toStringAsFixed(1) + " km/h"}",
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // --- DISTRACTION TRACKER UI ---
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
                    const Icon(
                      Icons.phone_android,
                      color: Colors.orange,
                      size: 30,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        "Distraction Tracker: ${distractionSeconds}s\n(Screen is ON while moving)",
                        style: const TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),

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
