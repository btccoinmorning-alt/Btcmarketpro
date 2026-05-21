import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'background_service.dart';

final FlutterLocalNotificationsPlugin _notifPlugin =
    FlutterLocalNotificationsPlugin();

const _permChannel = MethodChannel('com.btcmorning.btcmarketpro/permissions');

Future<void> _initNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await _notifPlugin.initialize(initSettings);
}

Future<void> _showNotification(String title, String body) async {
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
  await _notifPlugin.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title,
    body,
    details,
  );
}

bool _isExternalUrl(String url) {
  if (url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  const externalSchemes = ['tg', 'tel', 'mailto', 'intent', 'market'];
  if (externalSchemes.contains(uri.scheme)) return true;
  if (uri.host == 't.me' ||
      uri.host.endsWith('.t.me') ||
      uri.host == 'telegram.me') return true;
  if (uri.scheme != 'http' && uri.scheme != 'https') return true;
  if (uri.host.contains('btcmorning.com')) return false;
  return true;
}

const String _filePickerScript = r'''
(function() {
  try { window.RTCPeerConnection = undefined; } catch(e) {}
  try { window.webkitRTCPeerConnection = undefined; } catch(e) {}
  try { window.mozRTCPeerConnection = undefined; } catch(e) {}
  try { window.RTCIceCandidate = undefined; } catch(e) {}
  try { window.RTCSessionDescription = undefined; } catch(e) {}
  try {
    Object.defineProperty(navigator, 'mediaDevices', {
      get: function() {
        return {
          getUserMedia: function() {
            return Promise.reject(new DOMException('Permission denied', 'NotAllowedError'));
          },
          enumerateDevices: function() { return Promise.resolve([]); },
          getSupportedConstraints: function() { return {}; }
        };
      },
      configurable: false
    });
  } catch(e) {}
  try {
    navigator.getUserMedia = function(c, s, e) {
      if (e) e(new DOMException('Permission denied', 'NotAllowedError'));
    };
    window.getUserMedia = navigator.getUserMedia;
  } catch(e) {}
  var _origClick = HTMLInputElement.prototype.click;
  HTMLInputElement.prototype.click = function() {
    var el = this;
    if (el.type === 'file' && (el.accept || '').indexOf('image') !== -1) {
      window.flutter_inappwebview.callHandler('btcPickImage', el.capture ? 'camera' : 'gallery').then(function(dataUrl) {
        if (!dataUrl) return;
        fetch(dataUrl).then(function(r) { return r.blob(); }).then(function(blob) {
          var file = new File([blob], 'photo.jpg', { type: 'image/jpeg' });
          var dt = new DataTransfer();
          dt.items.add(file);
          el.files = dt.files;
          el.dispatchEvent(new Event('change', { bubbles: true }));
          el.dispatchEvent(new Event('input', { bubbles: true }));
        });
      }).catch(function() {});
      return;
    }
    return _origClick.apply(this, arguments);
  };
})();
''';

final _userScripts = UnmodifiableListView<UserScript>([
  UserScript(
    source: _filePickerScript,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  ),
]);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  await initWorkManager();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF071330),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const BTCMarketProApp());
}

class BTCMarketProApp extends StatelessWidget {
  const BTCMarketProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BTCMarketPro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A6FFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF071330),
        useMaterial3: true,
      ),
      home: const AppRoot(),
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  InAppWebViewController? _controller;
  bool _showSplash = true;
  bool _hasError = false;
  bool _hasInternet = true;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySub;
  bool _pollingStarted = false;
  Timer? _notifTimer;
  int _lastChecked = 0;

  static const String _homeUrl = 'https://www.btcmorning.com/btcmarketpro/';
  static const String _notifyUrl =
      'https://www.btcmorning.com/wp-content/plugins/btcmarketpro/notify_check.php';

  @override
  void initState() {
    super.initState();
    _lastChecked = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 300;
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet =
          results.isNotEmpty && results.first != ConnectivityResult.none;
      if (!mounted) return;
      setState(() => _hasInternet = hasNet);
    });
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted && _showSplash) setState(() => _showSplash = false);
    });
  }

  void _startForegroundPolling() {
    if (_pollingStarted) return;
    _pollingStarted = true;
    Future.delayed(const Duration(seconds: 5), _checkForNotifications);
    _notifTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
      await _checkForNotifications();
    });
  }

  Future<void> _checkForNotifications() async {
    if (!_hasInternet) return;
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse('$_notifyUrl?since=$_lastChecked');
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) return;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['success'] != true) return;
      if ((json['new_count'] as int? ?? 0) == 0) return;
      final items = json['items'] as List<dynamic>? ?? [];
      if (items.isEmpty) return;
      final item = items.first as Map<String, dynamic>;
      final label = item['label'] as String? ?? '🔔 BTCMarketPro';
      final title = item['title'] as String? ?? '';
      if (title.isNotEmpty) await _showNotification(label, title);
      _lastChecked = json['checked_at'] as int? ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000;
    } catch (_) {}
  }

  Future<void> _reloadPage() async {
    setState(() {
      _hasError = false;
      _showSplash = true;
      _pollingStarted = false;
    });
    await _controller?.reload();
  }

  Future<bool> _onWillPop() async {
    if (_controller != null && await _controller!.canGoBack()) {
      await _controller!.goBack();
      return false;
    }
    return _showExitDialog();
  }

  Future<bool> _showExitDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1F3C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Exit App',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Are you sure you want to exit BTCMarketPro?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No', style: TextStyle(color: Color(0xFF1A6FFF))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A6FFF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Yes', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  void dispose() {
    _connectivitySub.cancel();
    _notifTimer?.cancel();
    super.dispose();
  }

  Future<bool> _requestCameraPermissionIfNeeded() async {
    try {
      final hasPermission =
          await _permChannel.invokeMethod<bool>('checkPermissions') ?? false;
      if (!hasPermission) {
        await _permChannel.invokeMethod('requestPermissions');
        await Future.delayed(const Duration(milliseconds: 800));
        return await _permChannel.invokeMethod<bool>('checkPermissions') ?? false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _pickImageWithSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF0D1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt_rounded, color: Color(0xFF1A6FFF)),
                title: const Text('Camera', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded, color: Color(0xFF1A6FFF)),
                title: const Text('Gallery', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (source == null) return null;

    if (source == ImageSource.camera) {
      final granted = await _requestCameraPermissionIfNeeded();
      if (!granted) return null;
    }

    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  void _registerJsHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'btcPickImage',
      callback: (args) async {
        return await _pickImageWithSource();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF071330),
        body: SafeArea(
          child: Stack(
            children: [
              if (!_hasInternet)
                _NoInternetWidget(onRetry: _reloadPage)
              else if (_hasError)
                _ErrorWidget(onRetry: _reloadPage)
              else
                InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_homeUrl)),
                  initialUserScripts: _userScripts,
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    mediaPlaybackRequiresUserGesture: true,
                    allowFileAccessFromFileURLs: false,
                    allowUniversalAccessFromFileURLs: false,
                    useHybridComposition: true,
                    allowsInlineMediaPlayback: false,
                    domStorageEnabled: true,
                    databaseEnabled: true,
                    cacheEnabled: true,
                    userAgent:
                        'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
                        'AppleWebKit/537.36 (KHTML, like Gecko) '
                        'Chrome/124.0.0.0 Mobile Safari/537.36',
                  ),
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    _registerJsHandlers(controller);
                  },
                  onPermissionRequest: (controller, request) async {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.DENY,
                    );
                  },
                  shouldOverrideUrlLoading: (controller, navigationAction) async {
                    final url = navigationAction.request.url?.toString() ?? '';
                    if (url.isEmpty) return NavigationActionPolicy.ALLOW;
                    if (_isExternalUrl(url)) {
                      try {
                        await launchUrl(Uri.parse(url),
                            mode: LaunchMode.externalApplication);
                      } catch (_) {}
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                  onLoadStop: (controller, url) async {
                    if (!mounted) return;
                    _startForegroundPolling();
                    try {
                      await _permChannel.invokeMethod('setAppReady');
                    } catch (_) {}
                    setState(() {
                      _showSplash = false;
                      _hasError = false;
                    });
                  },
                  onReceivedError: (controller, request, error) {
                    if (!mounted) return;
                    if (request.isForMainFrame ?? false) {
                      setState(() {
                        _showSplash = false;
                        _hasError = true;
                      });
                    }
                  },
                ),
              if (_showSplash) const SplashScreen(),
            ],
          ),
        ),
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF071330),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: const Color(0xFF0D1F3C),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: const Color(0xFF1A6FFF).withOpacity(0.3),
                  width: 1.5,
                ),
              ),
              child: const Center(
                child: Text(
                  '₿',
                  style: TextStyle(
                    color: Color(0xFF1A6FFF),
                    fontSize: 58,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              'BTCMarketPro',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Advanced Crypto Platform',
              style: TextStyle(
                color: Color(0xFF1A6FFF),
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 40),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                color: Color(0xFF1A6FFF),
                strokeWidth: 2.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoInternetWidget extends StatelessWidget {
  final VoidCallback onRetry;
  const _NoInternetWidget({required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF071330),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 72, color: Colors.white24),
              const SizedBox(height: 20),
              const Text(
                'No Internet Connection',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please check your connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A6FFF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorWidget extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorWidget({required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF071330),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 72, color: Colors.redAccent),
              const SizedBox(height: 20),
              const Text(
                'Page Failed to Load',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Something went wrong. Please try again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A6FFF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}