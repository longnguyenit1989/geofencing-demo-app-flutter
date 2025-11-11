import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geofence_foreground_service/constants/geofence_event_type.dart';
import 'package:geofence_foreground_service/exports.dart';
import 'package:geofence_foreground_service/models/zone.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geofence_foreground_service/geofence_foreground_service.dart';
import 'package:permission_handler/permission_handler.dart';

const String BASE_URL = "http://192.168.1.43:8000";
final FlutterLocalNotificationsPlugin flnp = FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  const AndroidInitializationSettings initAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initIOS = DarwinInitializationSettings(
    requestSoundPermission: true,
    requestBadgePermission: true,
    requestAlertPermission: true,
  );
  const InitializationSettings initSettings =
      InitializationSettings(android: initAndroid, iOS: initIOS);
  await flnp.initialize(initSettings);
  await flnp
      .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>()
      ?.requestPermissions(alert: true, badge: true, sound: true);
}

Future<void> showNotyLocal(String zoneID, String shopName) async {
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'geofence_channel',
    'Geofence Notifications',
    description: 'Notification when entering store area',
    importance: Importance.max,
  );
  await flnp
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  final androidDetails = AndroidNotificationDetails(
    channel.id,
    channel.name,
    channelDescription: channel.description,
    importance: Importance.max,
    priority: Priority.high,
  );
  const iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
    threadIdentifier: 'geofence_noty',
  );
  final notificationDetails =
      NotificationDetails(android: androidDetails, iOS: iosDetails);

  await flnp.show(
    zoneID.hashCode & 0x7fffffff,
    'You have entered the store area',
    'Shop: $shopName',
    notificationDetails,
  );
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();

  GeofenceForegroundService().handleTrigger(
    backgroundTriggerHandler: (zoneID, triggerType) async {
      if (triggerType == GeofenceEventType.enter) {
        await callApiNoty(zoneID);
      }
      return true;
    },
  );
}

Future<String> callApiNoty(String zoneID) async {
  try {
    final url = Uri.parse('$BASE_URL/shops/notify');
    final body = jsonEncode({
      "shopIds": [int.tryParse(zoneID) ?? zoneID]
    });
    final res = await http.post(url,
        headers: {"Content-Type": "application/json"}, body: body);
    if (res.statusCode >= 200 && res.statusCode <= 300) {
      // final jsonResp = jsonDecode(res.body.trim());
      final sendPort = IsolateNameServer.lookupPortByName('noty_port');
      sendPort?.send({
        'zoneID': zoneID,
        'shopName': zoneID,
      });
    }
  } catch (_) {}
  return zoneID;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();

  final ReceivePort notyPort = ReceivePort();
  IsolateNameServer.registerPortWithName(
    notyPort.sendPort,
    'noty_port',
  );

  notyPort.listen((dynamic data) {
    final zoneID = data['zoneID'] as String;
    final shopName = data['shopName'] as String;
    showNotyLocal(zoneID, shopName);
  });

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Geofence Foreground Demo',
      home: GeofencePage(),
    );
  }
}

class GeofencePage extends StatefulWidget {
  const GeofencePage({super.key});

  @override
  State<GeofencePage> createState() => _GeofencePageState();
}

class _GeofencePageState extends State<GeofencePage> {
  final List<Zone> _zones = [];

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    await _requestPermissions();

    bool hasServiceStarted =
        await GeofenceForegroundService().startGeofencingService(
      contentTitle: 'App is running in background',
      contentText: 'Monitoring zones for store entry',
      notificationChannelId: 'geofence_channel',
      serviceId: 525600,
      callbackDispatcher: callbackDispatcher,
    );

    if (hasServiceStarted) {
      await _fetchShopsAndRegisterZones();
    }
  }

  Future<void> _requestPermissions() async {
    if (!await Permission.location.isGranted) {
      await Permission.location.request();
    }
    if (!await Permission.locationAlways.isGranted) {
      await Permission.locationAlways.request();
    }
    if (!await Permission.notification.isGranted) {
      await Permission.notification.request();
    }
    if (!await Permission.ignoreBatteryOptimizations.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  Future<void> _fetchShopsAndRegisterZones() async {
    try {
      final res = await http.post(
        Uri.parse('$BASE_URL/shops/nearby'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"latitude": 21.0085682, "longtitude": 105.8205329}),
      );
      final List shops = jsonDecode(res.body);
      print("shops response: $shops");
      for (var shop in shops) {
        final idStr = shop['id'].toString();
        final lat = double.parse(shop['latitude'].toString());
        final lng = double.parse(shop['longtitude'].toString());
        final radius = double.parse(shop['notifyRadius'].toString());
        final zone = Zone(
          id: idStr,
          radius: radius,
          coordinates: [LatLng(Angle.degree(lat), Angle.degree(lng))],
          triggers: [
            GeofenceEventType.enter,
            GeofenceEventType.exit,
            GeofenceEventType.dwell,
          ],
          expirationDuration: const Duration(days: 1),
          dwellLoiteringDelay: const Duration(seconds: 5),
          initialTrigger: GeofenceEventType.enter,
        );
        await GeofenceForegroundService().addGeofenceZone(zone: zone);
        _zones.add(zone);
      }
      setState(() {});
    } catch (e, st) {
      print('Exception fetching shops: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Geofence Foreground Service')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Store area tracking'),
            const SizedBox(height: 8),
            Text('Registered zones: ${_zones.length}'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () async {
                setState(() => _zones.clear());
              },
              child: const Text('Delete all regions'),
            ),
          ],
        ),
      ),
    );
  }
}
