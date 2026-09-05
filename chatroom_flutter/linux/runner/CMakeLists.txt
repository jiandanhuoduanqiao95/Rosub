cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# 导出运行时可查找符号（阶段 H1/H2 任务栏闪烁）：
# Dart 经 DynamicLibrary.process()（dlopen(NULL) + dlsym）查找 chatroom_set_urgency，
# 可执行文件默认不把自身符号加入 .dynsym 动态符号表，导致查找失败、闪烁静默失效。
# --export-dynamic 将全局符号导出，Dart 侧才能经 FFI 调用 GTK urgency 桥接。
target_link_libraries(${BINARY_NAME} PRIVATE "-Wl,--export-dynamic")

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
