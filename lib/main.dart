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
import 'package:permission_handler/permission_handler.dart';
import 'background_service.dart';

// ─── Bildirim ────────────────────────────────────────────────────────────────

final FlutterLocalNotificationsPlugin _notifPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _notifPlugin.initialize(
    const InitializationSettings(android: androidInit),
  );
}

Future<void> _showNotification(String title, String body) async {
  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'btcmarketpro_channel',
      'BTCMarketPro Notifications',
      channelDescription: 'News, Airdrops, Launchpads and Testnet alerts',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      playSound: true,
      enableVibration: true,
    ),
  );
  await _notifPlugin.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title,
    body,
    details,
  );
}

// ─── URL yardımcısı ───────────────────────────────────────────────────────────

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

// ─── JS: file input override ─────────────────────────────────────────────────

const String _filePickerScript = r'''
(function () {
  // WebRTC'yi tamamen kapat
  ['RTCPeerConnection','webkitRTCPeerConnection','mozRTCPeerConnection',
   'RTCIceCandidate','RTCSessionDescription'].forEach(function(k) {
    try { window[k] = undefined; } catch(e) {}
  });
  try {
    Object.defineProperty(navigator, 'mediaDevices', {
      get: function () {
        return {
          getUserMedia: function () {
            return Promise.reject(new DOMException('NotAllowed', 'NotAllowedError'));
          },
          enumerateDevices: function () { return Promise.resolve([]); },
          getSupportedConstraints: function () { return {}; }
        };
      },
      configurable: false
    });
  } catch (e) {}

  // Resim dosyası input tıklamalarını Flutter'a yönlendir
  var _orig = HTMLInputElement.prototype.click;
  HTMLInputElement.prototype.click = function () {
    var el = this;
    if (el.type === 'file' && (el.accept || '').indexOf('image') !== -1) {
      var mode = el.capture ? 'camera' : 'gallery';
      window.flutter_inappwebview
        .callHandler('btcPickImage', mode)
        .then(function (dataUrl) {
          if (!dataUrl) return;
          fetch(dataUrl)
            .then(function (r) { return r.blob(); })
            .then(function (blob) {
              var file = new File([blob], 'photo.jpg', { type: 'image/jpeg' });
              var dt = new DataTransfer();
              dt.items.add(file);
              el.files = dt.files;
              el.dispatchEvent(new Event('change', { bubbles: true }));
              el.dispatchEvent(new Event('input',  { bubbles: true }));
            });
        })
        .catch(function () {});
      return;
    }
    return _orig.apply(this, arguments);
  };
})();
''';

final _userScripts = UnmodifiableListView<UserScript>([
  UserScript(
    source: _filePickerScript,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  ),
]);

// ─── main ────────────────────────────────────────────────────────────────────

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

// ─── App ─────────────────────────────────────────────────────────────────────

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

// ─── AppRoot ─────────────────────────────────────────────────────────────────

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  InAppWebViewController? _webCtrl;
  bool _showSplash = true;
  bool _hasError   = false;
  bool _hasInternet = true;
  bool _pollingStarted = false;
  bool _notifPermAsked = false;

  late StreamSubscription<List<ConnectivityResult>> _connSub;
  Timer? _notifTimer;
  int _lastChecked = 0;

  static const _homeUrl   = 'https://www.btcmorning.com/btcmarketpro/';
  static const _notifyUrl =
      'https://www.btcmorning.com/wp-content/plugins/btcmarketpro/notify_check.php';

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _lastChecked = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 300;
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      setState(() {
        _hasInternet =
            results.isNotEmpty && results.first != ConnectivityResult.none;
      });
    });
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted && _showSplash) setState(() => _showSplash = false);
    });
  }

  @override
  void dispose() {
    _connSub.cancel();
    _notifTimer?.cancel();
    super.dispose();
  }

  // ── Bildirim polling ───────────────────────────────────────────────────────

  void _startPolling() {
    if (_pollingStarted) return;
    _pollingStarted = true;
    Future.delayed(const Duration(seconds: 5), _checkNotifs);
    _notifTimer =
        Timer.periodic(const Duration(minutes: 2), (_) => _checkNotifs());
  }

  Future<void> _checkNotifs() async {
    if (!_hasInternet) return;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final req  = await client.getUrl(Uri.parse('$_notifyUrl?since=$_lastChecked'));
      final resp = await req.close();
      if (resp.statusCode != 200) return;
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['success'] != true) return;
      if ((json['new_count'] as int? ?? 0) == 0) return;
      final items = json['items'] as List<dynamic>? ?? [];
      if (items.isEmpty) return;
      final item  = items.first as Map<String, dynamic>;
      final label = item['label'] as String? ?? '🔔 BTCMarketPro';
      final title = item['title'] as String? ?? '';
      if (title.isNotEmpty) await _showNotification(label, title);
      _lastChecked = json['checked_at'] as int? ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000;
    } catch (_) {}
  }

  // ── Bildirim izni: sayfa yüklendikten 45 sn sonra, bir kez sor ────────────

  void _askNotifPermissionLater() {
    if (_notifPermAsked) return;
    _notifPermAsked = true;
    Future.delayed(const Duration(seconds: 45), () async {
      if (!mounted) return;
      await Permission.notification.request();
    });
  }

  // ── Kamera izni ────────────────────────────────────────────────────────────

  Future<bool> _requestCameraPermission() async {
    var status = await Permission.camera.status;
    if (status.isGranted) return true;

    if (status.isPermanentlyDenied) {
      await _showPermissionDeniedDialog(
        icon: Icons.camera_alt_rounded,
        title: 'Camera Permission',
        message: 'Camera access is permanently denied.\nPlease enable it in Settings.',
      );
      return false;
    }

    status = await Permission.camera.request();
    return status.isGranted;
  }

  // ── Galeri izni ────────────────────────────────────────────────────────────

  Future<bool> _requestGalleryPermission() async {
    // Android 13+: READ_MEDIA_IMAGES | Android 12-: READ_EXTERNAL_STORAGE
    final permission = (Platform.isAndroid)
        ? Permission.photos
        : Permission.photos;

    var status = await permission.status;
    if (status.isGranted || status.isLimited) return true;

    if (status.isPermanentlyDenied) {
      await _showPermissionDeniedDialog(
        icon: Icons.photo_library_rounded,
        title: 'Gallery Permission',
        message: 'Gallery access is permanently denied.\nPlease enable it in Settings.',
      );
      return false;
    }

    status = await permission.request();
    return status.isGranted || status.isLimited;
  }

  // ── İzin reddedildi dialogu ────────────────────────────────────────────────

  Future<void> _showPermissionDeniedDialog({
    required IconData icon,
    required String title,
    required String message,
  }) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1F3C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: Icon(icon, color: const Color(0xFF1A6FFF), size: 40),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
          textAlign: TextAlign.center,
        ),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              openAppSettings();
            },
            icon: const Icon(Icons.settings_rounded, size: 16),
            label: const Text('Open Settings'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A6FFF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Fotoğraf seçici ────────────────────────────────────────────────────────

  Future<String?> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF0D1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Text(
                'Select Photo Source',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 16),
              _SourceTile(
                icon: Icons.camera_alt_rounded,
                label: 'Camera',
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
              const SizedBox(height: 8),
              _SourceTile(
                icon: Icons.photo_library_rounded,
                label: 'Gallery',
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (source == null) return null;

    // İzin kontrolü — sadece burada, açılışta değil
    if (source == ImageSource.camera) {
      final ok = await _requestCameraPermission();
      if (!ok) return null;
    } else {
      final ok = await _requestGalleryPermission();
      if (!ok) return null;
    }

    try {
      final file = await ImagePicker().pickImage(
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

  // ── JS handler kaydı ──────────────────────────────────────────────────────

  void _registerHandlers(InAppWebViewController c) {
    c.addJavaScriptHandler(
      handlerName: 'btcPickImage',
      callback: (_) async => _pickImage(),
    );
  }

  // ── Reload ────────────────────────────────────────────────────────────────

  Future<void> _reload() async {
    setState(() {
      _hasError = false;
      _showSplash = true;
      _pollingStarted = false;
    });
    await _webCtrl?.reload();
  }

  // ── Geri / çıkış ─────────────────────────────────────────────────────────

  Future<bool> _onBack() async {
    if (_webCtrl != null && await _webCtrl!.canGoBack()) {
      await _webCtrl!.goBack();
      return false;
    }
    return _exitDialog();
  }

  Future<bool> _exitDialog() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1F3C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Exit App',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text('Are you sure you want to exit BTCMarketPro?',
            style: TextStyle(color: Colors.white70)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No', style: TextStyle(color: Color(0xFF1A6FFF))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A6FFF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    return yes ?? false;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onBack() && mounted) SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF071330),
        body: SafeArea(
          child: Stack(
            children: [
              if (!_hasInternet)
                _NoInternetScreen(onRetry: _reload)
              else if (_hasError)
                _ErrorScreen(onRetry: _reload)
              else
                InAppWebView(
                  initialUrlRequest:
                      URLRequest(url: WebUri(_homeUrl)),
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
                  onWebViewCreated: (c) {
                    _webCtrl = c;
                    _registerHandlers(c);
                  },
                  // WebView'den gelen kamera/mikrofon isteklerini reddet
                  // (gerçek kamera ImagePicker ile açılıyor, WebRTC değil)
                  onPermissionRequest: (_, req) async => PermissionResponse(
                    resources: req.resources,
                    action: PermissionResponseAction.DENY,
                  ),
                  shouldOverrideUrlLoading: (_, nav) async {
                    final url = nav.request.url?.toString() ?? '';
                    if (_isExternalUrl(url)) {
                      try {
                        await launchUrl(
                          Uri.parse(url),
                          mode: LaunchMode.externalApplication,
                        );
                      } catch (_) {}
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                  onLoadStop: (_, __) {
                    if (!mounted) return;
                    setState(() {
                      _showSplash = false;
                      _hasError   = false;
                    });
                    _startPolling();
                    _askNotifPermissionLater(); // 45 sn sonra, bir kez
                  },
                  onReceivedError: (_, req, __) {
                    if (!mounted) return;
                    if (req.isForMainFrame ?? false) {
                      setState(() {
                        _showSplash = false;
                        _hasError   = true;
                      });
                    }
                  },
                ),
              if (_showSplash) const _SplashScreen(),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Source Tile widget ───────────────────────────────────────────────────────

class _SourceTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SourceTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2F55),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF1A6FFF)),
            const SizedBox(width: 16),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Splash ───────────────────────────────────────────────────────────────────

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

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
                  color: const Color(0xFF1A6FFF).withOpacity(0.35),
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

// ─── No Internet ─────────────────────────────────────────────────────────────

class _NoInternetScreen extends StatelessWidget {
  final VoidCallback onRetry;
  const _NoInternetScreen({required this.onRetry});

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
              const Text('No Internet Connection',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Please check your connection and try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 14)),
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

// ─── Error ────────────────────────────────────────────────────────────────────

class _ErrorScreen extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorScreen({required this.onRetry});

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
              const Text('Page Failed to Load',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Something went wrong. Please try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 14)),
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