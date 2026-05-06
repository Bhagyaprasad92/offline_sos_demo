// lib/features/safepulse/services/background_service.dart
import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/widgets.dart';
import '../engine/safepulse_engine.dart';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) async {
  if (notificationResponse.actionId == 'hide_battery_alert') {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hide_battery_alert', true);
  }
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  if (!(prefs.getBool("isMonitoring") ?? false)) {
    service.stopSelf();
    return;
  }

  final engine = SafePulseEngine();
  await engine.start();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  final Battery battery = Battery();

  service.on('stopService').listen((event) async {
    engine.stop();
    await flutterLocalNotificationsPlugin.cancelAll();
    service.stopSelf();
  });

  Timer.periodic(const Duration(seconds: 2), (timer) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool("isMonitoring") ?? false)) {
      engine.stop();
      await flutterLocalNotificationsPlugin.cancelAll();
      service.stopSelf();
      timer.cancel();
      return;
    }
  });

  Timer.periodic(const Duration(seconds: 5), (timer) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool("isMonitoring") ?? false)) {
      timer.cancel();
      return;
    }
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        flutterLocalNotificationsPlugin.show(
          888,
          '🛡️ SafePulse AI Active',
          'Monitoring sensors and location autonomously.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'safepulse_silent_v4',
              'SafePulse AI Service',
              ongoing: true,
              importance: Importance.low,
              priority: Priority.low,
            ),
          ),
        );
      }
    }

    bool isLocationOn = false;
    try {
      isLocationOn = await Geolocator.isLocationServiceEnabled();
    } catch (e) {}
    
    await prefs.setBool('sys_isLocationOn', isLocationOn);

    if (!isLocationOn) {
      flutterLocalNotificationsPlugin.show(
        889,
        '⚠️ SafePulse: Location Disabled',
        'Turn on Location so SOS can broadcast your coordinates.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'safepulse_alerts_v1',
            'System Alerts',
            importance: Importance.low,
            priority: Priority.low,
          ),
        ),
      );
    } else {
      flutterLocalNotificationsPlugin.cancel(889);
    }

    bool isBatterySaverOn = false;
    try {
      isBatterySaverOn = await battery.isInBatterySaveMode;
    } catch (e) {}
    await prefs.setBool('sys_isBatterySaverOn', isBatterySaverOn);

    bool isAlertHidden = prefs.getBool('hide_battery_alert') ?? false;

    if (isBatterySaverOn && !isAlertHidden) {
      flutterLocalNotificationsPlugin.show(
        890,
        '⚠️ SafePulse: Battery Saver Active',
        'Disable Battery Saver to prevent Android from killing the AI sensors.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'safepulse_alerts_v1',
            'System Alerts',
            importance: Importance.low,
            priority: Priority.low,
            actions: <AndroidNotificationAction>[
              AndroidNotificationAction(
                'hide_battery_alert',
                'Hide',
                cancelNotification: true,
              ),
            ],
          ),
        ),
      );
    } else if (!isBatterySaverOn) {
      await prefs.setBool('hide_battery_alert', false);
      flutterLocalNotificationsPlugin.cancel(890);
    }
  });
}

class BackgroundServiceHelper {
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'safepulse_silent_v4',
      'SafePulse AI Service',
      description: 'Keeps SafePulse running silently in the background.',
      importance: Importance.low,
    );

    const AndroidNotificationChannel alertChannel = AndroidNotificationChannel(
      'safepulse_alerts_v1',
      'System Alerts',
      description: 'Warnings for GPS and Battery Saver.',
      importance: Importance.low,
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(alertChannel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'safepulse_silent_v4',
        initialNotificationTitle: '🛡️ SafePulse AI Active',
        initialNotificationContent: 'Monitoring sensors...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(autoStart: false, onForeground: onStart),
    );
  }
}
