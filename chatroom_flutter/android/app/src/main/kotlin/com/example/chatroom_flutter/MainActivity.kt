package com.example.chatroom_flutter

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

class MainActivity : FlutterActivity() {

    private var permissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Q1 真机反馈二轮（首开闪退待定位）：Java 层未捕获异常面包屑——
        // 落盘 crash_log.txt，下次启动 Dart 侧读取展示（复制回传排查）
        installCrashLogger()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 阶段 R1 真机二轮：flutter_webrtc 1.6.x 在 getUserMedia 启动时经
        // AudioSwitchManager（JitPack audioswitch）改音频模式/请求焦点/枚举
        // 蓝牙路由——真机（OneUI）在该时刻闪退，Linux 无此组件同代码正常。
        // 关闭其音频会话管理，WebRTC 采播走 Android 默认路由；崩溃栈拿到
        // 前不再回开。
        com.cloudwebrtc.webrtc.audio.AudioSwitchManager
            .setAudioSessionManagementEnabled(false)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chatroom/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openFile" -> openFile(call.argument<String>("path"), result)
                    // ---- Q1 三轮/四轮：文件分享导出 / 提示音走通知音量 ----
                    "shareFile" -> shareFile(call.argument<String>("path"), result)
                    "playNotifySound" -> playNotifySound(
                        call.argument<String>("path"), result)
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "openBatteryOptimizationSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    // ---- Q1 真机反馈二轮：保活 / 通知 / 返回 / 崩溃日志 ----
                    "startKeepAlive" -> {
                        try {
                            KeepAliveService.start(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopKeepAlive" -> {
                        try {
                            KeepAliveService.stop(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "showMessageNotification" -> {
                        showMessageNotification(
                            call.argument<String>("title") ?: "新消息",
                            call.argument<String>("body") ?: "",
                        )
                        result.success(true)
                    }
                    // ---- Q1 六轮（问题3）：应用提示音统一 + 客户端内震动 ----
                    "setupMessageChannel" -> setupMessageChannel(result)
                    // ---- Q1 七轮（问题1）：后台传输进度通知 ----
                    "showTransferNotification" -> showTransferNotification(
                        call.argument<String>("title") ?: "文件传输",
                        (call.argument<Number>("progress") as? Number)?.toInt()
                            ?: 0,
                        result,
                    )
                    "cancelTransferNotification" -> {
                        try {
                            NotificationManagerCompat.from(this)
                                .cancel(TRANSFER_NOTIF_ID)
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    "cancelMessageNotifications" -> {
                        try {
                            NotificationManagerCompat.from(this)
                                .cancel(MESSAGE_NOTIF_ID)
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            ContextCompat.checkSelfPermission(
                                this, Manifest.permission.POST_NOTIFICATIONS
                            ) != PackageManager.PERMISSION_GRANTED
                        ) {
                            permissionResult?.success(false)
                            permissionResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQ_POST_NOTIFICATIONS,
                            )
                        } else {
                            result.success(true)
                        }
                    }
                    // ---- 阶段 R1：通话运行时权限（audio=RECORD_AUDIO，
                    // video 追加 CAMERA；S+ 追加蓝牙路由所需的
                    // BLUETOOTH_CONNECT；全部授予才返回 true） ----
                    "requestCallPermissions" -> {
                        val video = call.argument<Boolean>("video") ?: false
                        val wanted = mutableListOf(Manifest.permission.RECORD_AUDIO)
                        if (video) wanted.add(Manifest.permission.CAMERA)
                        if (Build.VERSION.SDK_INT >= 31) {
                            wanted.add(Manifest.permission.BLUETOOTH_CONNECT)
                        }
                        val missing = wanted.filter {
                            ContextCompat.checkSelfPermission(this, it) !=
                                    PackageManager.PERMISSION_GRANTED
                        }
                        if (missing.isEmpty()) {
                            result.success(true)
                        } else {
                            // 应答槽位防覆盖：上一个权限请求未回时先按拒绝
                            // 收口（对已完成的 Result 重复 reply 会
                            // IllegalStateException 闪退）
                            permissionResult?.success(false)
                            permissionResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                missing.toTypedArray(),
                                REQ_CALL_PERMISSIONS,
                            )
                        }
                    }
                    "moveToBackground" -> {
                        moveTaskToBack(true)
                        result.success(true)
                    }
                    "getLastCrashLog" -> {
                        try {
                            val f = File(filesDir, "crash_log.txt")
                            result.success(if (f.exists()) f.readText() else null)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "clearCrashLog" -> {
                        try {
                            File(filesDir, "crash_log.txt").delete()
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_POST_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            permissionResult?.success(granted)
            permissionResult = null
        }
        if (requestCode == REQ_CALL_PERMISSIONS) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            permissionResult?.success(granted)
            permissionResult = null
        }
    }

    // ---- 崩溃日志面包屑（Java 层未捕获异常；native SIGSEGV 不在此列） ----

    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                File(filesDir, "crash_log.txt")
                    .writeText("time=${System.currentTimeMillis()}\n$sw")
            } catch (_: Exception) {
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    // ---- 应用外新消息通知（横幅 + 震动 + 提示音，参考微信） ----

    /**
     * Q1 六轮（问题3）：消息通知渠道改用**应用提示音**（生成式 chime
     * WAV）——原渠道用系统默认音，与客户端内提示音不一致。渠道声音等
     * 设置创建后不可变，故每次启动删除重建（幂等）。
     * Q1 八轮（问题2 修复）：声音改挂**打包内置资源**
     * `android.resource://<pkg>/raw/notify_chime`——七轮的 file:// 外部
     * 目录 Uri 在 OneUI 上 SystemUI 读不到（只有震动无声）；资源 Uri
     * 是系统通知自定义音的标准做法，全 ROM 可靠。res/raw/notify_chime.wav
     * 与 TaskbarNotifier 生成式 chime 同算法固化（改音色需同步重新生成）。
     */
    private fun setupMessageChannel(result: MethodChannel.Result) {
        try {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                result.success(false)
                return
            }
            manager.deleteNotificationChannel(MESSAGE_CHANNEL_ID)
            val channel = NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "新消息",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                setSound(
                    Uri.parse("android.resource://$packageName/raw/notify_chime"),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                // 自定义震动节奏（短-短）
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 180, 100, 180)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
            }
            manager.createNotificationChannel(channel)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    // ---- Q1 七轮：后台文件传输进度系统通知 ----

    /**
     * 传输进度常驻通知（静默低优先级渠道；进行中同 id 反复 notify
     * 即原地更新进度条）。仅后台/锁屏期间由 Dart 侧调用。
     */
    private fun showTransferNotification(
        title: String,
        progress: Int,
        result: MethodChannel.Result,
    ) {
        try {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        TRANSFER_CHANNEL_ID,
                        "文件传输进度",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        setShowBadge(false)
                        setSound(null, null)
                        enableVibration(false)
                    }
                )
            }
            val notification = NotificationCompat.Builder(this, TRANSFER_CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText("$progress%")
                .setProgress(100, progress.coerceIn(0, 100), false)
                .setOngoing(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .build()
            NotificationManagerCompat.from(this)
                .notify(TRANSFER_NOTIF_ID, notification)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun showMessageNotification(title: String, body: String) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "新消息",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                // 缺省即系统通知音；自定义震动节奏（短-短）
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 180, 100, 180)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
            }
            manager.createNotificationChannel(channel)
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        try {
            NotificationManagerCompat.from(this).notify(MESSAGE_NOTIF_ID, notification)
        } catch (_: SecurityException) {
        }
    }

    private fun openFile(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.success(false)
            return
        }
        try {
            val file = File(path)
            if (!file.exists()) {
                result.success(false)
                return
            }
            val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                FileProvider.getUriForFile(this, "$packageName.fileProvider", file)
            } else {
                Uri.fromFile(file)
            }
            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(uri, resolveMimeType(path))
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun resolveMimeType(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "mp4", "m4v", "mov" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "mp3" -> "audio/mpeg"
            "wav" -> "audio/wav"
            "ogg" -> "audio/ogg"
            "m4a" -> "audio/mp4"
            "pdf" -> "application/pdf"
            "txt", "md", "log" -> "text/plain"
            "zip" -> "application/zip"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        }
    }

    // ---- Q1 四轮：分享导出文件 / 提示音走通知音量 ----

    /**
     * 系统分享面板导出文件（FileProvider 只读 URI）。
     * Q1 四轮（问题5）：Android 不做"打开所在目录"（接收目录位于应用
     * 内部存储，文件管理器不可见），分享是可靠的导出通道。
     */
    private fun shareFile(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.success(false)
            return
        }
        try {
            val file = File(path)
            if (!file.exists()) {
                result.success(false)
                return
            }
            val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                FileProvider.getUriForFile(this, "$packageName.fileProvider", file)
            } else {
                Uri.fromFile(file)
            }
            val intent = Intent(Intent.ACTION_SEND)
                .setType(resolveMimeType(path))
                .putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(Intent.createChooser(intent, "分享文件"))
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    /**
     * Q1 四轮（问题6）：应用内新消息提示音改走**通知音量**——原实现经
     * media_kit（mpv/AudioTrack 媒体流）播放，随媒体音量归零而静音；
     * 现以 USAGE_NOTIFICATION_COMMUNICATION_INSTANT 用途播放
     * （系统路由到通知流，与微信提示音一致）。
     * Q1 六轮（问题3）：播放后按通知渠道同款节奏震动（短-短）——
     * 客户端内外提醒行为一致。
     */
    private var notifyPlayer: MediaPlayer? = null

    private fun playNotifySound(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.success(false)
            return
        }
        try {
            notifyPlayer?.release()
            notifyPlayer = null
            val player = MediaPlayer()
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            player.setDataSource(path)
            player.prepare()
            player.setOnCompletionListener {
                it.release()
                if (notifyPlayer === it) notifyPlayer = null
            }
            notifyPlayer = player
            player.start()
            vibrateNotify()
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    /** 通知同款震动节奏（短-短）；无震动器/系统限制时静默 */
    private fun vibrateNotify() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (vibrator?.hasVibrator() != true) return
            val pattern = longArrayOf(0, 180, 100, 180)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, -1)
            }
        } catch (_: Exception) {
        }
    }

    companion object {
        const val MESSAGE_CHANNEL_ID = "chatroom_messages"
        const val MESSAGE_NOTIF_ID = 2001
        const val TRANSFER_CHANNEL_ID = "chatroom_transfer"
        const val TRANSFER_NOTIF_ID = 2002
        const val REQ_POST_NOTIFICATIONS = 1001
        const val REQ_CALL_PERMISSIONS = 1002
    }
}
