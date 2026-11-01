package com.example.chatroom_flutter

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * 来电通知（opt8 功能三）：振铃且 App 不在前台时由 Dart 侧经
 * AndroidSystem.showIncomingCallNotification 触发；接听/拒绝/超时/取消
 * 等收敛点由 Dart 调 cancelIncomingCallNotification 撤除。
 *
 * 通道 IMPORTANCE_HIGH（heads-up 必需）但静音无震动——铃声由 Dart 侧
 * PlatformCallSound 循环播放（USAGE_NOTIFICATION_RINGTONE，避免双响）；
 * 应用级震动本轮不做（用户决策，是否震动由系统通知设置/ROM 决定）。
 *
 * full-screen intent：锁屏全屏拉起 MainActivity（call_lockscreen=1 置
 * setShowWhenLocked/turnScreenOn）；Android 14+ 需 USE_FULL_SCREEN_INTENT
 * 特殊授权，未授权时系统自动降级 heads-up——**仍要发通知，勿 return**。
 *
 * 接听/拒绝 action v1 经 MainActivity 拉起 App（用户已接受的取舍：拒绝
 * 会短暂到前台），由 Dart 侧 consumeCallIntent 消费 pendingCallAction，
 * 不做完全后台拒绝（无 BroadcastReceiver 方案）。
 *
 * 勿设 largeIcon（gc17 vivo 通知模板出现左右重复徽标）；勿设渠道提示音
 * （铃声由 Dart 播放）；setTimeoutAfter(45s) 仅为原生兜底，Dart 30s
 * 振铃超时会先撤销通知。
 */
object IncomingCallNotifier {
    const val CHANNEL_ID = "chatroom_incoming_call_v1"
    const val NOTIF_ID = 1004

    private const val REQ_OPEN = 1004
    private const val REQ_ANSWER = 1005
    private const val REQ_DECLINE = 1006

    /**
     * 渠道 create-if-absent/更新（幂等）。应用启动路径（MainActivity 的
     * setupCallChannel 同处）调用一次；show() 内兜底调用。
     * **禁用 deleteNotificationChannel**——若在 FGS 运行中删除渠道会被
     * 系统拒绝（SecurityException 进程崩溃，opt1 真机实锤）。
     */
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "来电",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    setSound(null, null)
                    enableVibration(false)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                    setShowBadge(false)
                }
            )
        } catch (_: Exception) {
        }
    }

    fun show(context: Context, title: String, body: String) {
        // Android 13+ 通知运行时权限未授予时静默返回（与
        // showMessageNotification 一致），不崩溃
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureChannel(context)
        try {
            // 三个 PendingIntent requestCode 必须不同，否则 FLAG_UPDATE_CURRENT
            // 下互相覆盖（action 全部退化成 open）
            val baseIntent = {
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra(CallForegroundService.EXTRA_OPEN_CALL, true)
                    putExtra(MainActivity.EXTRA_CALL_LOCKSCREEN, true)
                }
            }
            val openIntent = PendingIntent.getActivity(
                context,
                REQ_OPEN,
                baseIntent(),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val answerIntent = PendingIntent.getActivity(
                context,
                REQ_ANSWER,
                baseIntent().putExtra(MainActivity.EXTRA_CALL_ACTION, "accept"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val declineIntent = PendingIntent.getActivity(
                context,
                REQ_DECLINE,
                baseIntent().putExtra(MainActivity.EXTRA_CALL_ACTION, "decline"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification_white)
                .setContentTitle(title)
                .setContentText(body)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)
                .setOnlyAlertOnce(true)
                .setContentIntent(openIntent)
                // Android 14+ 全屏通知权限不足时系统忽略此意图，降级 heads-up
                .setFullScreenIntent(openIntent, true)
                .setTimeoutAfter(45_000L)
                .addAction(0, "拒绝", declineIntent)
                .addAction(0, "接听", answerIntent)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIF_ID, notification)
        } catch (_: Exception) {
            // SecurityException（权限竞态）/ PendingIntent / SystemUI 异常
            // 一律静默——来电通知失败不崩溃，前台 CallScreen 与铃声仍在
        }
    }

    fun cancel(context: Context) {
        try {
            NotificationManagerCompat.from(context).cancel(NOTIF_ID)
        } catch (_: Exception) {
        }
    }
}
