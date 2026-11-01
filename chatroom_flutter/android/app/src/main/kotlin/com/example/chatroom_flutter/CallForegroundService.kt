package com.example.chatroom_flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.ImageView
import androidx.core.app.NotificationCompat

/**
 * 通话专属前台服务（opt1 P5/P6 + opt8 功能二悬浮球）。
 *
 * 背景：KeepAliveService 是 specialUse 型 FGS，只保进程不豁免媒体采集——
 * Android 14+ 在后台/熄屏采集麦克风或摄像头，要求存在 **microphone|camera
 * 型** FGS（类型与实际使用匹配），否则采集被系统静默切断（表现为熄屏后
 * 对端听不到/看不到本端）。通话开始时由 Dart 侧启动（语音=microphone、
 * 视频追加 camera），通话结束停止；通知"通话中"带 contentIntent 打开
 * MainActivity（extra open_call=1），Dart 侧检测后恢复通话界面（P6）。
 *
 * opt8 功能二（通话悬浮球）：通话进行中（calling/connecting/active）且
 * App 退后台时，Dart 侧发 ACTION_SHOW_BUBBLE 显示系统级悬浮球
 * （SYSTEM_ALERT_WINDOW，TYPE_APPLICATION_OVERLAY）；点击经
 * open_call 链路回通话界面（与 FGS 通知同一恢复语义），可拖动、
 * touch slop 内视为点击。气泡 action 绝不重复 startForeground，也绝不
 * 把进行中的视频 FGS 降级成纯 microphone 型——ensureForeground 仅在
 * 服务尚未前台时启动，且 Dart 侧必须携带当前通话的 video 标志。
 *
 * 与消息 KeepAliveService 并存（渠道不同、生命周期不同）：通话中退后台
 * 时两条通知同时存在属预期；消息保活的生命周期门控不受影响（Q1 五轮
 * 定稿只能增强禁止削弱）。
 *
 * 通知渠道沿用 v2 命名体系（vivo SystemUI 渠道级渲染缓存，勿降级回退）。
 */
class CallForegroundService : Service() {

    /** startAsForeground 成功后置位；气泡 action 到达时据此免重复启动 */
    private var foregroundStarted = false

    private var bubbleView: View? = null
    private var bubbleParams: WindowManager.LayoutParams? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        when (intent?.action) {
            ACTION_SHOW_BUBBLE -> {
                // 气泡 action：仅在服务尚未前台时以 FGS 语义拉起
                // （勿重复 startForeground——重复通知/类型抖动无意义）
                ensureForeground(video)
                showBubble()
                return START_STICKY
            }
            ACTION_HIDE_BUBBLE -> {
                // 隐藏球不需要前台服务：服务不在通话前台时直接撤场——
                // 勿在此做 FGS 前台拉起（会为隐藏一个可能不存在的球
                // 挂出"通话中"常驻通知 = 幽灵 FGS）；服务正在通话前台
                // 时保持运行（只收球，不影响通话）
                hideBubble()
                if (!foregroundStarted) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                return START_STICKY
            }
        }
        // 普通启动/刷新：**每次都重新 startForeground**（opt5 升级语义，
        // 勿改回"已前台则跳过"的单次门控）——首次来电振铃期 RECORD_AUDIO
        // 未授予时降级 specialUse 并置 foregroundStarted，用户接听授权后
        // Dart 侧 _onCallChanged 再次 startCallForeground 必须能完成
        // specialUse → microphone|camera 升级；单次门控会让 FGS 永远停在
        // specialUse，熄屏/退后台采集被系统切断（opt5 已修回归）。
        startAsForeground(video)
        return START_STICKY
    }

    /** 仅用于 ACTION_SHOW_BUBBLE：服务尚未前台时以 FGS 语义拉起 */
    private fun ensureForeground(video: Boolean) {
        if (!foregroundStarted) {
            startAsForeground(video)
        }
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
        // onCreate 置 open_call 标志，Dart 侧 consume 后 restore 通话页）。
        // 勿带 call_lockscreen extra——普通"通话中"通知不覆盖锁屏（隐私）。
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
            foregroundStarted = true
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
            foregroundStarted = true
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
                foregroundStarted = true
            } catch (e2: Exception) {
                android.util.Log.e(
                    "CallForegroundService",
                    "specialUse FGS also rejected, stopping service", e2
                )
                foregroundStarted = false
                stopSelf()
            }
        }
    }

    // ============================================================
    // opt8 功能二：通话悬浮球（SYSTEM_ALERT_WINDOW overlay）
    // ============================================================

    private fun bubbleEdgeMarginPx(): Int =
        (12 * resources.displayMetrics.density).toInt()

    private fun bubbleSizePx(): Int =
        (56 * resources.displayMetrics.density).toInt()

    /**
     * 系统栏高度（状态栏/导航栏；内部 dimen 资源，取不到回退 0）——
     * 悬浮球位置 clamp 据此避开状态栏与手势导航区（F2-04"不遮挡
     * 系统栏关键区域"）。
     */
    private fun systemBarInsetsPx(): Pair<Int, Int> {
        var status = 0
        var nav = 0
        try {
            val res = resources
            val statusId = res.getIdentifier("status_bar_height", "dimen", "android")
            if (statusId > 0) status = res.getDimensionPixelSize(statusId)
            val navId = res.getIdentifier("navigation_bar_height", "dimen", "android")
            if (navId > 0) nav = res.getDimensionPixelSize(navId)
        } catch (_: Exception) {
        }
        return status to nav
    }

    /** 位置 clamp：屏幕内 + 避开状态栏/导航栏 + 12dp 边距 */
    private fun clampBubble(params: WindowManager.LayoutParams) {
        val metrics = resources.displayMetrics
        val size = bubbleSizePx()
        val margin = bubbleEdgeMarginPx()
        val (statusBar, navBar) = systemBarInsetsPx()
        params.x = params.x.coerceIn(
            margin, (metrics.widthPixels - size - margin).coerceAtLeast(margin)
        )
        params.y = params.y.coerceIn(
            statusBar + margin,
            (metrics.heightPixels - navBar - size - margin)
                .coerceAtLeast(statusBar + margin)
        )
    }

    private fun showBubble() {
        // 特殊权限未授予：降级为仅通知入口（P6 链路不受影响），不崩溃
        if (!Settings.canDrawOverlays(this)) return
        if (bubbleView != null) return
        try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val metrics = resources.displayMetrics
            val size = bubbleSizePx()
            val margin = bubbleEdgeMarginPx()
            val params = WindowManager.LayoutParams(
                size,
                size,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_PHONE
                },
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                // 初始位：右边缘、垂直居中（clamp 避开系统栏）
                x = metrics.widthPixels - size - margin
                y = (metrics.heightPixels - size) / 2
                clampBubble(this)
            }
            val view = ImageView(this).apply {
                setImageResource(R.drawable.ic_call_bubble)
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(0xE616181C.toInt())
                }
                setPadding(size / 4, size / 4, size / 4, size / 4)
            }
            // 拖动 + 点击：移动超 touch slop 视为拖动，否则触发点击回通话
            val touchSlop = ViewConfiguration.get(this).scaledTouchSlop
            var downRawX = 0f
            var downRawY = 0f
            var startX = 0
            var startY = 0
            var moved = false
            val tapIntent = PendingIntent.getActivity(
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
            view.setOnTouchListener { v, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downRawX = event.rawX
                        downRawY = event.rawY
                        startX = params.x
                        startY = params.y
                        moved = false
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = event.rawX - downRawX
                        val dy = event.rawY - downRawY
                        if (!moved &&
                            (kotlin.math.abs(dx) > touchSlop ||
                                    kotlin.math.abs(dy) > touchSlop)) {
                            moved = true
                        }
                        if (moved) {
                            params.x = (startX + dx).toInt()
                            params.y = (startY + dy).toInt()
                            try {
                                clampBubble(params)
                                wm.updateViewLayout(v, params)
                            } catch (_: Exception) {
                            }
                        }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        if (!moved) {
                            try {
                                tapIntent.send()
                            } catch (_: Exception) {
                            }
                        }
                        true
                    }
                    else -> false
                }
            }
            wm.addView(view, params)
            bubbleView = view
            bubbleParams = params
        } catch (_: Exception) {
            // overlay 添加失败（权限被撤销/系统限制）：悬浮球降级，不崩溃
            bubbleView = null
            bubbleParams = null
        }
    }

    private fun hideBubble() {
        val view = bubbleView ?: return
        bubbleView = null
        bubbleParams = null
        try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.removeView(view)
        } catch (_: Exception) {
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 旋转/分屏：按新屏幕尺寸（含系统栏变化）重新 clamp 当前位置
        val view = bubbleView ?: return
        val params = bubbleParams ?: return
        try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            clampBubble(params)
            wm.updateViewLayout(view, params)
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        // 统一清理：球随服务销毁移除（勿留幽灵球）
        hideBubble()
        foregroundStarted = false
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 任务被划掉：Flutter engine 已不可用，通话状态无法继续——
        // 隐藏球、撤除来电通知（进程可能存活至 setTimeoutAfter 前的
        // 幽灵通知窗口）并撤场，避免幽灵球与幽灵 FGS
        hideBubble()
        IncomingCallNotifier.cancel(this)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    companion object {
        const val CHANNEL_ID = "chatroom_call_v2"
        const val NOTIF_ID = 1003
        const val EXTRA_VIDEO = "video"
        const val EXTRA_OPEN_CALL = "open_call"

        /** opt8 功能二：悬浮球显隐 action（经 startService 携带 video） */
        const val ACTION_SHOW_BUBBLE = "chatroom.action.SHOW_CALL_BUBBLE"
        const val ACTION_HIDE_BUBBLE = "chatroom.action.HIDE_CALL_BUBBLE"

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

        /**
         * 显示悬浮球。**video 必须传当前通话实际类型**——服务未运行时
         * startForegroundService 拉起并以该类型就位；服务已运行时气泡
         * action 不重启 FGS（ensureForeground no-op），类型不会被降级。
         */
        fun showBubble(context: Context, video: Boolean) {
            val intent = Intent(context, CallForegroundService::class.java)
                .setAction(ACTION_SHOW_BUBBLE)
                .putExtra(EXTRA_VIDEO, video)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** 隐藏悬浮球（startService——只做 hide 不值得以 FGS 语义拉起） */
        fun hideBubble(context: Context, video: Boolean) {
            try {
                val intent = Intent(context, CallForegroundService::class.java)
                    .setAction(ACTION_HIDE_BUBBLE)
                    .putExtra(EXTRA_VIDEO, video)
                context.startService(intent)
            } catch (_: Exception) {
                // 服务不在（后台限制）——最终 onDestroy 兜底移除
            }
        }
    }
}
