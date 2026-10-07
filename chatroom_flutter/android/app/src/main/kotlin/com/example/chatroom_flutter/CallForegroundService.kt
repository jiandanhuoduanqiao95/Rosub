package com.example.chatroom_flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 通话专属前台服务（opt1 P5/P6）。
 *
 * 背景：KeepAliveService 是 specialUse 型 FGS，只保进程不豁免媒体采集——
 * Android 14+ 在后台/熄屏采集麦克风或摄像头，要求存在 **microphone|camera
 * 型** FGS（类型与实际使用匹配），否则采集被系统静默切断（表现为熄屏后
 * 对端听不到/看不到本端）。通话开始时由 Dart 侧启动（语音=microphone、
 * 视频追加 camera），通话结束停止；通知"通话中"带 contentIntent 打开
 * MainActivity（extra open_call=1），Dart 侧检测后恢复通话界面（P6）。
 *
 * 与消息 KeepAliveService 并存（渠道不同、生命周期不同）：通话中退后台
 * 时两条通知同时存在属预期；消息保活的生命周期门控不受影响（Q1 五轮
 * 定稿只能增强禁止削弱）。
 *
 * 通知渠道沿用 v2 命名体系（vivo SystemUI 渠道级渲染缓存，勿降级回退）。
 */
class CallForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        startAsForeground(video)
        return START_STICKY
    }

    private fun startAsForeground(video: Boolean) {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 渠道由 MainActivity.setupCallChannel 在应用启动时删除重建
            // （IMPORTANCE_DEFAULT——LOW 在 vivo OriginOS 不展示卡片，
            // P6"点通知回通话"入口失效）。**FGS 内禁止 deleteNotification-
            // Channel**（"Not allowed to delete channel ... with a
            // foreground service" SecurityException 进程崩溃，真机实锤），
            // 此处仅 create-if-absent 兜底。
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "通话中",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                }
            )
        }
        // 点击通知回到通话界面：打开 MainActivity（singleTop，onNewIntent/
        // onCreate 置 open_call 标志，Dart 侧 consume 后 restore 通话页）
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_OPEN_CALL, true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_white)
            .setContentTitle("Rosub 通话中")
            .setContentText("音视频通话进行中，点按此处返回通话")
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentIntent)
            .setForegroundServiceBehavior(
                NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE
            )
            .build()
        if (Build.VERSION.SDK_INT < 34) {
            startForeground(NOTIF_ID, notification)
            return
        }
        // opt5（1.0.2-opt5，真机 SecurityException 闪退修复）：Android 14+
        // 的 microphone 型 FGS 在 startForeground 时**硬校验 RECORD_AUDIO
        // 已授予**（any-of 捕获权限 + eligible state），未授予直接
        // SecurityException 炸进程。vivo OriginOS 的"仅本次允许"会在进程
        // 结束后回收权限——下次来电（振铃期就启 FGS，早于运行时权限申请）
        // 必撞。策略：
        //   ① 权限感知选型——RECORD_AUDIO 授予才用 microphone（视频且
        //      CAMERA 授予才追加 camera）；未授予降级 specialUse（仅保
        //      连接/信令，后台媒体采集会被系统切断，前台通话不受影响；
        //      权限授妥后 Dart 侧 _onCallChanged 会再次启动本服务完成
        //      升级回 microphone 型）。
        //   ② SecurityException 双层兜底——先试 specialUse，再失败则
        //      stopSelf 撤场（规避 FGS 启动超时异常），**任何路径不崩**。
        val micGranted = androidx.core.content.ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.RECORD_AUDIO
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val camGranted = androidx.core.content.ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.CAMERA
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        var type = 0
        if (micGranted) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        if (video && camGranted) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        if (type == 0) {
            type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        }
        try {
            startForeground(NOTIF_ID, notification, type)
        } catch (e: SecurityException) {
            try {
                android.util.Log.w(
                    "CallForegroundService",
                    "FGS type $type rejected, downgrading to specialUse: $e"
                )
                startForeground(
                    NOTIF_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } catch (e2: Exception) {
                android.util.Log.e(
                    "CallForegroundService",
                    "specialUse FGS also rejected, stopping service", e2
                )
                stopSelf()
            }
        }
    }

    companion object {
        const val CHANNEL_ID = "chatroom_call_v2"
        const val NOTIF_ID = 1003
        const val EXTRA_VIDEO = "video"
        const val EXTRA_OPEN_CALL = "open_call"

        fun start(context: Context, video: Boolean) {
            val intent = Intent(context, CallForegroundService::class.java)
                .putExtra(EXTRA_VIDEO, video)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallForegroundService::class.java))
        }
    }
}
