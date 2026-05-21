# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# InAppWebView
-keep class com.pichillilorenzo.flutter_inappwebview.** { *; }
-dontwarn com.pichillilorenzo.flutter_inappwebview.**

# Connectivity Plus
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# File Picker
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# Permission Handler
-keep class com.baseflow.permissionhandler.** { *; }

# WebView
-keep class android.webkit.** { *; }
-keep class androidx.webkit.** { *; }

# Kotlin
-keep class kotlin.** { *; }
-dontwarn kotlin.**

# General
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception