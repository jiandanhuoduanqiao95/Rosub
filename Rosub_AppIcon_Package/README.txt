Rosub 应用图标交付包

01_Source：原始参考图、1024 位图母版、透明 Logo、SVG 矢量重绘、Illustrator 可打开的 .ai 源文件。
SVG 为独立贝塞尔路径与渐变，无嵌入位图。AI 使用 EPS/PostScript Level 3 兼容格式，包含矢量路径和渐变，非现代 Illustrator 私有原生格式；可在 Illustrator 中打开后另存为当前版本 AI。未在 Illustrator 实机验证。
矢量稿为另行重绘，造型和渐变经过简化，不是原始 3D 工程文件，也不与位图逐像素一致。
位图母版通过 imagegen 根据原图适配，透明主体与方形母版分别生成，细节存在轻微差异。原始图片完整保留。

02_iOS：AppIcon-1024.png 为 RGB，无透明通道、无预制圆角。AppIcon.appiconset 含 iPhone/iPad 常用尺寸和 Contents.json，可加入 Xcode 资源目录。
Legacy_Reference 为清单列出的额外尺寸。83.5 的 @1x/@3x 会产生半像素，因此仅提供实际可用的 @2x=167px。1024@2x/@3x 为插值导出，不增加原图细节。
03_Android：Google Play 为 RGBA 512，Alpha 全不透明。res 包含五档前景、背景、旧版图标及 v26 adaptive XML。默认前景放在画布中央 60% 范围，满足清单 66/108 边界。将 res 合并进项目，Manifest 指向 @mipmap/ic_launcher；roundIcon 可指向 @mipmap/ic_launcher_round。
04_Web_PWA：favicon ICO 含 16/32/48；另有 PNG、180 touch icon、192/512 PWA、maskable 和 SVG。maskable 主体置于中间 60% 方框，主体本身进一步内缩，保留裁切安全空间。manifest 为接入示例，按网站部署路径调整 start_url 和图标路径。
05_Desktop：Windows ICO 含 16/24/32/48/64/128/256；macOS ICNS 含标准 16/32/64/128/256/512/1024 表示。未在真实设备和操作系统安装验证。
06_Optional：深浅主题、启动页、登录页、官网、商店截图透明 Logo、聊天水印原素材，以及另行简化的白色单色通知图标（24/36/48/72/96）。水印使用时由应用设置透明度。

所有交付 PNG 为每通道 8 bit，附 sRGB ICC。RGBA 为总 32 bit，RGB 为总 24 bit。SVG/AI 为矢量，无固定位深。
manifest.json 记录 PNG 尺寸与模式；SHA256SUMS.txt 提供校验值；validation.json 记录技术检查结果。
图标在小尺寸下会损失立体细节，通知图标采用简化聊天气泡图形。
