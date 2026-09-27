package com.example.chatroom_flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 后台保活服务（Q1 五轮问题1 重大回归修复：恢复前台服务形态）。
 *
 * 历史：二轮=常驻 FGS（通知全程可见）→ 三轮=生命周期门控 FGS（前台
 * 零通知、退后台才出现）→ 四轮=普通 START_STICKY 服务（零通知）→
 * **五轮回退到三轮形态**。四轮方案的下场：无前台状态时 OneUI/OriginOS
 * 深度休眠会冻结/回收进程——socket 死了也无人重连，后台彻底收不到
 * 新消息（对端显示送达）。Android 12+ 冻结机制只豁免前台服务，侧载
 * 应用没有厂商推送通道（微信靠的是厂商推送 + OEM 白名单，无法复刻），
 * **前台服务通知是后台收消息的唯一可靠代价**，不可再省。
 *
 * 前台使用期间服务不运行（零通知）；退后台由 Dart 生命周期启动
 * （paused），回前台立即停止（resumed）——通知只在后台期间存在。
 * IMPORTANCE_MIN + 静默：无提示音/无横幅/无角标，收起在通知栏底部。
 *
 * 图标（gc17 用户决策）：只设 smallIcon 白色单色气泡、**不设
 * largeIcon**——vivo OriginOS 通知卡片左侧恒渲染应用图标（品牌已
 * 可见），设大图标只会引出模板右侧的应用徽标重复；若将来确需
 * largeIcon，必须走 Icon.createWithResource（BitmapFactory.decode-
 * Resource 对 anydpi-v26 自适应图标 XML 静默返回 null，见 gc16）。
 */
class KeepAliveService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        return START_STICKY
    }

    private fun startAsForeground() {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "后台连接",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                }
            )
        }
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_white)
            .setContentTitle("Rosub 在线中")
            .setContentText("退到后台仍在保持消息连接，及时接收新消息")
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setForegroundServiceBehavior(
                NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE
            )
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    companion object {
        const val CHANNEL_ID = "chatroom_keepalive_v2"
        const val NOTIF_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, KeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }
    }
}
