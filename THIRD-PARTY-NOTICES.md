# Third-Party Notices

Rosub 以 MIT 许可发布（见 [LICENSE](LICENSE)）。本文件列出随本项目分发或构建时引入的第三方组件及其许可声明。各组件的完整许可文本随其源码分发（vendored 目录/上游仓库）。

## 1. 服务端（Python）

| 组件 | 许可证 | 版权 |
|---|---|---|
| bcrypt | Apache-2.0 | Donald Stufft, Individual Contributors |
| cryptography | Apache-2.0 / BSD-3 | The cryptography developers |
| pyOpenSSL | Apache-2.0 | The pyOpenSSL developers |
| PyYAML | MIT | Kirill Simonov |

文本：https://www.apache.org/licenses/LICENSE-2.0 、https://opensource.org/licenses/BSD-3-Clause 、https://opensource.org/licenses/MIT

## 2. 客户端（Flutter / Dart）

| 组件 | 许可证 | 说明 |
|---|---|---|
| flutter_webrtc（vendored 于 `third_party/flutter_webrtc`） | MIT | Copyright (c) 2018 湖北捷智云技术有限公司；完整文本见该目录 `LICENSE`；含两个再分发组件声明（见其 `NOTICE`）：shiguredo SimulcastVideoEncoderFactoryWrapper（Apache-2.0, Copyright 2017 Lyo Kato/Shiguredo Inc.）与 react-native-webrtc（MIT, Copyright 2015 Howard Yang）。本项目在其上维护补丁（见 `third_party/flutter_webrtc/README-PATCH.md`）。Android 端经 Maven 引入 `io.github.webrtc-sdk:android`（libwebrtc m150 派生，源码：https://github.com/webrtc-sdk/libwebrtc ） |
| media_kit / media_kit_video / media_kit_libs_* | MIT | 视频/音频播放框架，https://github.com/media-kit/media-kit |
| libmpv（随 Android APK 与 Windows 构建捆绑） | **LGPL-2.1-or-later** | 由 media-kit 构建脚本生成：Android `media-kit/libmpv-android-video-build`（default flavor）、Windows `media-kit/libmpv-win32-video-build`（构建开关实测 `mpv -Dgpl=false` + `ffmpeg --disable-gpl`，不含 GPL 编码组件）。相应源码与构建脚本：https://github.com/media-kit/libmpv-android-video-build 、https://github.com/media-kit/libmpv-win32-video-build 。本应用以动态链接方式使用该库（Android 为 APK 内动态 .so，Windows 为随包 DLL），符合 LGPL 动态链接再分发要求 |
| ANGLE（Windows 构建期引入） | BSD-2 / Apache-2.0 混合 | https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES |
| sqlite3（Dart 包及捆绑的 SQLite 引擎） | MIT / Public Domain | https://github.com/simolus3/sqlite3.dart |
| flutter_secure_storage、path_provider、shared_preferences、sqflite、sqflite_common_ffi、file_picker、ffi、intl、archive、crypto、logger | MIT / BSD-3 | 均为宽松许可，文本见各自 pub.dev 页面与源码仓库 |
| dart_protocol（`dart_protocol/`，本仓库内置） | 与本项目同许可（MIT） | 项目自研协议层 |

## 3. 字体

| 组件 | 许可证 | 说明 |
|---|---|---|
| Noto Color Emoji（`chatroom_flutter/assets/fonts/NotoColorEmoji.ttf`） | SIL Open Font License 1.1 | Copyright 2022 Google Inc.；"Noto" is a trademark of Google Inc.；完整许可全文见 [chatroom_flutter/assets/fonts/OFL-1.1.txt](chatroom_flutter/assets/fonts/OFL-1.1.txt)；字体以未修改形式分发 |

## 4. 图标与品牌素材

`Rosub_AppIcon_Package/01_Source/` 与 `chatroom_flutter/assets/` 中的应用图标、Logo 为本项目原创素材（生成记录见 `Rosub_AppIcon_Package/01_Source/Generation_notes.txt`），随 MIT 许可分发。
