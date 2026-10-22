package com.lithesh.filo

import android.content.pm.PackageInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "filo/app_info")
            .setMethodCallHandler { call, result ->
                if (call.method != "getVersion") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                try {
                    val packageInfo: PackageInfo = packageManager.getPackageInfo(packageName, 0)
                    @Suppress("DEPRECATION")
                    val buildNumber = packageInfo.versionCode
                    result.success("${packageInfo.versionName ?: "unknown"} · Build $buildNumber")
                } catch (error: Exception) {
                    result.error("version_unavailable", "Installed version could not be read.", null)
                }
            }
    }
}
