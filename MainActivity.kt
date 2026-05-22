package com.btcmorning.btcmarketpro

import android.os.Bundle
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WebView.setWebContentsDebuggingEnabled(false)
        // Açılışta HİÇBİR izin istenmez.
        // Tüm izinler Dart tarafında, kullanıcı aksiyonu anında istenir.
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.btcmorning.btcmarketpro/permissions"
        ).setMethodCallHandler { call, result ->
            result.success(true)
        }
    }
}