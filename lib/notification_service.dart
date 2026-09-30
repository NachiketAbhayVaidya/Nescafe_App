import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Requests notification permission, keeps the device's FCM token in sync on
/// the user's Firestore doc (users/{uid}.fcmToken), and shows a local
/// notification when a push arrives while the app is open in the foreground.
///
/// The actual "send" side lives in notify_order_status.js (a Node script
/// using firebase-admin) — this class only handles the device/client half.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'order_status_channel',
    'Order updates',
    description: 'Notifies you when your order status changes',
    importance: Importance.high,
  );

  // Separate channel so the admin's "order paid" alert always plays a sound.
  static const AndroidNotificationChannel _paidChannel = AndroidNotificationChannel(
    'paid_order_channel',
    'Paid orders',
    description: 'Beeps when a customer pays for an order',
    importance: Importance.max,
    playSound: true,
  );

  bool _initialized = false;

  /// One beep + a small heads-up notification for a freshly paid order.
  /// Used on the admin device only.
  Future<void> beepForPaidOrder({required String customerName, required double amount}) async {
    try {
      await _localNotifications.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'New paid order',
        '$customerName paid ₹${amount.toStringAsFixed(0)}',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _paidChannel.id,
            _paidChannel.name,
            channelDescription: _paidChannel.description,
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            onlyAlertOnce: true,
          ),
          iOS: const DarwinNotificationDetails(presentSound: true, presentAlert: true),
        ),
      );
    } catch (e) {
      debugPrint('Could not play paid-order alert: $e');
    }
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _messaging.requestPermission(alert: true, badge: true, sound: true);

    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_paidChannel);

    await _localNotifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );

    // App is open and in the foreground: FCM won't auto-show a system
    // notification, so we display one ourselves via flutter_local_notifications.
    FirebaseMessaging.onMessage.listen((message) {
      final notification = message.notification;
      if (notification == null) return;
      _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    });

    await _saveTokenForCurrentUser();
    _messaging.onTokenRefresh.listen((_) => _saveTokenForCurrentUser());
  }

  Future<void> _saveTokenForCurrentUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final token = await _messaging.getToken();
      if (token == null) return;
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {'fcmToken': token},
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('Could not save FCM token: $e');
    }
  }

  /// Call on logout so a stale token isn't left pointing at a signed-out user.
  Future<void> clearTokenForUser(String uid) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        {'fcmToken': FieldValue.delete()},
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('Could not clear FCM token: $e');
    }
  }
}
