import 'dart:convert';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

const _taskName = 'btcNotificationCheck';
const _taskTag  = 'com.btcmorning.btcmarketpro.notif';
const _notifyUrl =
    'https://www.btcmorning.com/wp-content/plugins/btcmarketpro/notify_check.php';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _taskName) {
      await _backgroundNotificationCheck();
    }
    return Future.value(true);
  });
}

Future<void> _backgroundNotificationCheck() async {
  try {
    final notifPlugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await notifPlugin.initialize(initSettings);

    final since = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 900;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    final uri     = Uri.parse('$_notifyUrl?since=$since');
    final request = await client.getUrl(uri);
    final response = await request.close();

    if (response.statusCode != 200) return;

    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;

    if (json['success'] != true) return;
    if ((json['new_count'] as int? ?? 0) == 0) return;

    final items = json['items'] as List<dynamic>? ?? [];
    if (items.isEmpty) return;

    final limit = items.length > 3 ? 3 : items.length;
    for (int i = 0; i < limit; i++) {
      final item  = items[i] as Map<String, dynamic>;
      final label = item['label'] as String? ?? '🔔 BTCMarketPro';
      final title = item['title'] as String? ?? '';
      if (title.isEmpty) continue;

      const androidDetails = AndroidNotificationDetails(
        'btcmarketpro_channel',
        'BTCMarketPro Notifications',
        channelDescription: 'News, Airdrops, Launchpads and Testnet alerts',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        playSound: true,
        enableVibration: true,
      );
      const details = NotificationDetails(android: androidDetails);
      await notifPlugin.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + i,
        label,
        title,
        details,
      );
    }
  } catch (_) {}
}

Future<void> initWorkManager() async {
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: false,
  );
  await Workmanager().registerPeriodicTask(
    _taskTag,
    _taskName,
    frequency: const Duration(minutes: 15),
    initialDelay: const Duration(minutes: 1),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(minutes: 5),
  );
}