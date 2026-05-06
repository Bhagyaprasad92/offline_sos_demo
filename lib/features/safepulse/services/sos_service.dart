// lib/features/safepulse/services/sos_service.dart
import 'package:telephony_fix/telephony.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:permission_handler/permission_handler.dart';

class SosService {
  final Telephony telephony = Telephony.instance;

  final List<String> emergencyContacts = [
    "+919381363374",
    "+918143837005",
    "+916305560939",
    "+919391479869",
    "+919435608337",
    "+916302535979",
  ];

  Function(String message)? onLog;
  Function()? onCallReturned;
  bool _isAwaitingCallReturn = false;

  Future<void> triggerOfflineSOS(
    double lat,
    double lng, {
    bool hasLocation = true,
    int? locationAgeSec,
    double speedMs = 0.0,
  }) async {
    final now = DateTime.now();
    String timestamp =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    String locText;

    if (hasLocation) {
      int staleThreshold = speedMs > 10.0 ? 10 : 30;
      if (locationAgeSec != null && locationAgeSec > staleThreshold) {
        locText = "Loc(stale): https://maps.google.com/?q=$lat,$lng";
      } else {
        locText = "Loc: https://maps.google.com/?q=$lat,$lng";
      }
    } else {
      locText = "Loc: UNAVAILABLE. Call immediately.";
    }

    String payload = "SOS! Crash detected.\nTime: $timestamp\n$locText";
    if (payload.length > 150) {
      payload = payload.substring(0, 150);
    }

    final smsStatus = await Permission.sms.status;
    if (smsStatus.isPermanentlyDenied) {
      openAppSettings();
      onLog?.call(
        "⚠️ SMS Permission Permanently Denied. Open Settings to enable.",
      );
    } else if (await Permission.sms.isGranted) {
      onLog?.call(
        "Broadcasting offline SMS to ${emergencyContacts.length} contacts...",
      );

      Set<String> processedNumbers = {};

      for (String number in emergencyContacts) {
        telephony.sendSms(
          to: number,
          message: payload,
          statusListener: (SendStatus status) {
            if (processedNumbers.contains(number)) return;
            if (status == SendStatus.SENT) {
              onLog?.call("SUCCESS: SMS to $number.");
              processedNumbers.add(number);
            } else if (status != SendStatus.DELIVERED) {
              onLog?.call("FAILED: SMS to $number.");
              processedNumbers.add(number);
            }
          },
        );
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } else {
      onLog?.call("⚠️ SMS Permission Denied. Skipping offline broadcast.");
    }

    if (emergencyContacts.isNotEmpty) {
      final phoneStatus = await Permission.phone.status;
      if (phoneStatus.isPermanentlyDenied) {
        openAppSettings();
        onLog?.call(
          "⚠️ Phone Permission Permanently Denied. Open Settings to enable.",
        );
      } else if (await Permission.phone.isGranted) {
        String primaryContact = emergencyContacts.first;
        onLog?.call("Initiating Fallback Call to $primaryContact...");

        _isAwaitingCallReturn = true;
        bool? callSuccess = await FlutterPhoneDirectCaller.callNumber(
          primaryContact,
        );

        if (callSuccess != true) {
          onLog?.call("FAILED: Could not initiate call.");
          _isAwaitingCallReturn = false;
        }
      } else {
        onLog?.call("⚠️ Phone Permission Denied. Skipping fallback call.");
      }
    }
  }

  void checkCallReturn() {
    if (_isAwaitingCallReturn) {
      _isAwaitingCallReturn = false;
      onCallReturned?.call();
    }
  }
}
