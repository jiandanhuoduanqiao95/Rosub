#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// 主窗口句柄（供任务栏闪烁等窗口级操作使用）
static GtkWindow* g_app_window = nullptr;

// 任务栏紧急提示（图标闪烁，类微信未读提醒）：由 Dart 经
// DynamicLibrary.process() 调用，urgent=1 闪烁 / 0 清除。
// - extern "C"：保持 C 符号名，Dart lookupFunction 按名查找
// - used：release 构建 -ffunction-sections --gc-sections 下防止被裁剪
// - visibility("default")：配合 CMake 的 --export-dynamic 确保进入 .dynsym
// - g_idle_add 转发：Dart UI isolate 线程 ≠ GTK 主线程，GTK 调用必须
//   在主循环线程执行（g_idle_add 线程安全），避免跨线程 GDK 访问竞态。
struct _UrgencyData {
  GtkWindow* win;
  gboolean urgent;
};

static gboolean apply_urgency_cb(gpointer user_data) {
  auto* d = static_cast<_UrgencyData*>(user_data);
  if (d->win != nullptr) {
    gtk_window_set_urgency_hint(d->win, d->urgent);
  }
  g_free(d);
  return G_SOURCE_REMOVE;
}

extern "C" __attribute__((used, visibility("default")))
void chatroom_set_urgency(int urgent) {
  auto* d = g_new(_UrgencyData, 1);
  d->win = g_app_window;
  d->urgent = urgent != 0;
  g_idle_add(apply_urgency_cb, d);
}

// 阶段 N3（P2-4 文件拖拽发送）：GTK 拖拽接收 —— 把拖入窗口的文件
// （text/uri-list）解析为本地路径，经 MethodChannel("chatroom/dnd")
// 的 "files" 方法转发给 Dart 侧（走既有上传通道，复用 M8 大文件分流）。
//
// 生命周期（P-70 修复）：Dart 侧 setMethodCallHandler 会替换 messenger 里
// 同名 channel 的 handler 并触发 destroy_notify（g_object_unref），若不
// 提前 ref，channel 在首次注册 Dart handler 时即被销毁，拖拽回调里
// fl_method_channel_invoke_method 落到悬空指针（CRITICAL:
// assertion 'FL_IS_METHOD_CHANNEL(self)' failed）。因此 new 后立即
// g_object_ref 保活，回调用静态指针 + FL_IS_METHOD_CHANNEL 防御检查。
static FlMethodChannel* g_dnd_channel = nullptr;

static void drag_data_received_cb(GtkWidget* widget, GdkDragContext* context,
                                  gint x, gint y,
                                  GtkSelectionData* selection_data,
                                  guint info, guint time, gpointer user_data) {
  if (g_dnd_channel == nullptr || !FL_IS_METHOD_CHANNEL(g_dnd_channel)) {
    return;
  }
  gchar** uris = gtk_selection_data_get_uris(selection_data);
  if (uris != nullptr) {
    FlValue* files = fl_value_new_list();
    for (int i = 0; uris[i] != nullptr; i++) {
      gchar* path = g_filename_from_uri(uris[i], nullptr, nullptr);
      if (path != nullptr) {
        fl_value_append_take(files, fl_value_new_string(path));
        g_free(path);
      }
    }
    // 参数直接传路径 List（与 Dart 侧 call.arguments as List 对齐；
    // 旧实现包一层 map {"files": [...]} 导致 Dart 侧强转 List 抛错，
    // 拖拽静默无反应）。args 由 invoke 同步序列化，调用后统一释放。
    if (fl_value_get_length(files) > 0) {
      fl_method_channel_invoke_method(g_dnd_channel, "files", files, nullptr,
                                      nullptr, nullptr);
    }
    fl_value_unref(files);
    g_strfreev(uris);
  }
  gtk_drag_finish(context, TRUE, FALSE, time);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  g_app_window = window;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "chatroom_flutter");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "chatroom_flutter");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // 阶段 N3（P2-4 文件拖拽发送）：注册窗口拖拽目标（text/uri-list），
  // 拖入文件 → drag_data_received_cb → MethodChannel("chatroom/dnd")。
  // P-70/P-71 修复：① channel new 必须提供标准 method codec（与 Dart 侧
  // MethodChannel 默认 codec 匹配）——旧实现传 nullptr 触发
  // 'FL_IS_METHOD_CODEC(codec)' 断言失败 + g_object_ref 悬空 CRITICAL，
  // 拖拽通道从未建立；② Dart 侧 setMethodCallHandler 会替换 messenger 里
  // 同名 channel 的 handler 并触发 destroy_notify（g_object_unref），
  // 因此 new 后立即 g_object_ref 保活，回调用静态指针 + FL_IS_METHOD_CHANNEL
  // 防御检查。
  g_dnd_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "chatroom/dnd", FL_METHOD_CODEC(fl_standard_method_codec_new()));
  g_object_ref(g_dnd_channel);
  GtkTargetEntry drag_targets[] = {{(gchar*)"text/uri-list", 0, 0}};
  gtk_drag_dest_set(GTK_WIDGET(window), GTK_DEST_DEFAULT_ALL, drag_targets, 1,
                    GDK_ACTION_COPY);
  g_signal_connect(window, "drag-data-received",
                   G_CALLBACK(drag_data_received_cb), nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
