import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geofence_foreground_service/constants/geofence_event_type.dart';
import 'package:geofence_foreground_service/exports.dart';
import 'package:geofence_foreground_service/models/zone.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geofence_foreground_service/geofence_foreground_service.dart';
import 'package:permission_handler/permission_handler.dart';

const String BASE_URL = "http://192.168.1.43:8000";
const String KEY_NOTY_PORT = "noty_port";
const String KEY_ZONEID = "zoneID";
const String KEY_SHOP_NAME = "shopName";

const String KEY_USER_ZONE_CURRENT_LOCATION = "user_zone_current_location";
const String KEY_EXIT_ZONE = "exit_zone";
const double RADIUS_EXIT_ZONE = 800;

const String KEY_ACTION = "action";

final FlutterLocalNotificationsPlugin flnp = FlutterLocalNotificationsPlugin();

final List<Zone> _zones = [];

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
      await Future.delayed(const Duration(seconds: 1));

      if (zoneID == KEY_USER_ZONE_CURRENT_LOCATION &&
          triggerType == GeofenceEventType.exit) {
        final sendPort = IsolateNameServer.lookupPortByName(KEY_NOTY_PORT);
        sendPort?.send(
            {KEY_ZONEID: zoneID, KEY_ACTION: KEY_EXIT_ZONE, KEY_SHOP_NAME: ''});
        print('callbackDispatcher: user exit zone');
        return true;
      }

      if (zoneID != KEY_USER_ZONE_CURRENT_LOCATION &&
          triggerType == GeofenceEventType.enter) {
        await callApiNoty(zoneID);
      }
      return true;
    },
  );
}

Future<void> callApiNoty(String zoneID) async {
  try {
    final url = Uri.parse('$BASE_URL/shops/notify');
    final body = jsonEncode({
      "shopIds": [int.tryParse(zoneID) ?? zoneID]
    });
    final res = await http.post(url,
        headers: {"Content-Type": "application/json"}, body: body);
    if (res.statusCode >= 200 && res.statusCode <= 300) {
      print('callApiNoty success');
      // final jsonResp = jsonDecode(res.body.trim());
      final sendPort = IsolateNameServer.lookupPortByName(KEY_NOTY_PORT);
      sendPort?.send({
        KEY_ZONEID: zoneID,
        KEY_SHOP_NAME: zoneID,
      });
    }
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();

  final ReceivePort receivePort = ReceivePort();
  IsolateNameServer.registerPortWithName(
    receivePort.sendPort,
    KEY_NOTY_PORT,
  );

  receivePort.listen((dynamic data) async {
    final zoneID = data[KEY_ZONEID] as String? ?? '';
    final shopName = data[KEY_SHOP_NAME] as String? ?? '';

    if (data[KEY_ACTION] == KEY_EXIT_ZONE) {
      print('receivePort listen data: $data');
      await _removeAllZones();
      await _registerUserCurrentLocationZone();
      await _fetchShopsAndRegisterZones();
      return;
    }

    if (shopName.isNotEmpty) {
      showNotyLocal(zoneID, shopName);
    }
  });

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const MyApp());
}

Future<void> _removeAllZones() async {
  if (_zones.isNotEmpty) {
    for (var zone in _zones) {
      await GeofenceForegroundService().removeGeofenceZone(zoneId: zone.id);
    }
    _zones.clear();
    print('All geofence zones removed.');
  }
}

Future<void> _registerUserCurrentLocationZone() async {
  final pos = await _getCurrentPosition();
  final zone = Zone(
    id: KEY_USER_ZONE_CURRENT_LOCATION,
    radius: RADIUS_EXIT_ZONE,
    coordinates: [
      LatLng(Angle.degree(pos.latitude), Angle.degree(pos.longitude))
    ],
    triggers: [GeofenceEventType.exit],
    expirationDuration: const Duration(days: 1),
    initialTrigger: GeofenceEventType.exit,
  );
  await GeofenceForegroundService().addGeofenceZone(zone: zone);
  _zones.add(zone);
  print('_registerUserCurrentLocationZone');
}

Future<void> _fetchShopsAndRegisterZones() async {
  final currentPosition = await _getCurrentPosition();
  try {
    final res = await http.post(
      Uri.parse('$BASE_URL/shops/nearby'),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "latitude": currentPosition.latitude,
        "longtitude": currentPosition.longitude
      }),
    );
    final List shops = jsonDecode(res.body);
    print("currentPosition: $currentPosition");
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
        ],
        expirationDuration: const Duration(days: 1),
        dwellLoiteringDelay: const Duration(seconds: 5),
        initialTrigger: GeofenceEventType.enter,
      );
      await GeofenceForegroundService().addGeofenceZone(zone: zone);
      _zones.add(zone);
    }
  } catch (e, st) {
    print('Exception fetching shops: $e\n$st');
  }
}

Future<Position> _getCurrentPosition() async {
  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 1, // 1 m will get newest location
    ),
  );
  return position;
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
      await _registerUserCurrentLocationZone();
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
                await _removeAllZones();
              },
              child: const Text('Delete all regions'),
            ),
          ],
        ),
      ),
    );
  }
}
