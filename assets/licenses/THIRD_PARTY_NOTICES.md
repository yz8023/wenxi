# 第三方组件

AsterLink Flutter 使用下列开放源代码组件；原作者的版权与许可声明保留。

项目原创代码及适用移植实现的 AGPL-3.0 许可见根目录 LICENSE 和 assets/licenses/AsterLink-LICENSE.txt。独立第三方组件仍保留下述各自许可；完整范围与内置 SDK 的组合分发说明见 docs/LICENSING.md。

## Gopeed

Gopeed 1.8.1（GopeedLab 及贡献者），GPL-3.0。完整许可位于 assets/licenses/Gopeed-LICENSE.txt 和 native/gopeed/LICENSE。对应的修改源码、构建脚本、go.mod / go.sum 与依赖源码 native/gopeed/vendor/ 随工程提供；修改记录见 native/README.md。

上游：https://github.com/GopeedLab/gopeed/tree/v1.8.1

分发包含此内核的组合构建时，需保留适用的 GPL 许可与对应源码。签名密钥不属于分发源码。构建产物不进入 Git 历史，但重建所需的内核源码、依赖与修改记录随源码提供。

## LanzouAPI

蓝奏单文件解析参考用户提供的 LanzouAPI 1.3.110，MIT License，Copyright (c) 2018 MHanL。保留完整许可于 assets/licenses/LanzouAPI-LICENSE.txt，协议与页面读取独立移植为 Dart，并适配当前下载节点的确认表单。

上游：https://github.com/hanximeng/LanzouAPI

HTML DOM 解析使用 html 0.15.7 与 csslib 1.0.2，BSD 许可由 Flutter 构建工具收录。应用无需部署或调用该项目的 PHP 服务。

## LanZouCloud-API

蓝奏文件夹的分页字段、响应状态和子目录 DOM 结构参考 LanZouCloud-API，MIT License，Copyright (c) 2019 zaxtyson。完整许可保留于 assets/licenses/LanZouCloud-API-LICENSE.txt。按公开页面数据独立适配为 Dart，加入分页去重、有限重试、取消、缓存限制和持久下载来源刷新，不执行 Python 参考代码或网页脚本。

参考版本：https://github.com/zaxtyson/LanZouCloud-API/tree/3bb917f6baf873d83b1e8e6fb2df74c60c4d8cb3

## BoxPlayer

光鸭云盘与阿里云盘的协议入口和操作流程参考 gaozhangmin/boxplayer，提交 `80d1be6d8a17d8b86327d1146492863ffba872aa`（2026-09-24 取得）。上游使用 GPL-3.0，完整许可保留于 assets/licenses/BoxPlayer-LICENSE.txt。实现适配为本工程的 Dart 连接器，并核对当日官方网页的接口和设备签名协议；未使用上游的私有 OpenAPI 应用密钥。相关来源及移植差异见 docs/CLOUD-PROVIDERS-2026-09-24.md。分发相关衍生实现时应保留适用许可、版权声明和对应源码。

上游：https://github.com/gaozhangmin/boxplayer/tree/80d1be6d8a17d8b86327d1146492863ffba872aa

## OpenList 与网盘 SDK

蓝奏云优享版、腾讯微云和中国联通云盘的协议与操作流程参考 OpenList，固定提交 `893457cd50d954b4a1a81727273b073193b1997d`（2026-09-24 取得）。OpenList 采用 AGPL-3.0，完整许可保留于 assets/licenses/OpenList-LICENSE.txt。相关驱动适配为本工程的 Dart 连接器，新增账号隔离、取消检查、分页完整性校验和本机下载来源恢复；来源和改动记录见 docs/OPENLIST-CLOUDS-SMS-2026-09-24.md。

上游：https://github.com/OpenListTeam/OpenList/tree/893457cd50d954b4a1a81727273b073193b1997d

协议结构和加密参数同时参考以下 Apache-2.0 SDK，原许可随资源保留。本工程没有打包这些 Go SDK 的二进制，也没有调用第三方代理服务。

- foxxorcat/weiyun-sdk-go v0.1.4：https://github.com/foxxorcat/weiyun-sdk-go/tree/v0.1.4；许可 assets/licenses/weiyun-sdk-go-LICENSE.txt。
- OpenListTeam/wopan-sdk-go v0.1.5：https://github.com/OpenListTeam/wopan-sdk-go/tree/v0.1.5；许可 assets/licenses/wopan-sdk-go-LICENSE.txt。
- foxxorcat/mopan-sdk-go v0.1.6：https://github.com/foxxorcat/mopan-sdk-go/tree/v0.1.6；许可 assets/licenses/mopan-sdk-go-LICENSE.txt。

分发包含这些移植实现的版本时，应保留适用的 AGPL、GPL、Apache 许可与对应源码。联通云盘图标来自其官方网页资源，标识权利归服务提供者。

## 友盟 Android SDK

Android 构建内置友盟+移动统计 SDK，通过 Gradle 获取，版本记录在 android/gradle/libs.versions.toml。该 SDK 适用供应商条款，不在项目 AGPL 许可的重新授权范围内。它与 GPL/AGPL 组件的组合分发兼容性需要单独确认；本说明未为上游代码添加许可例外。数据处理与当前默认行为见 docs/PRIVACY.md，供应商政策：https://www.umeng.com/page/policy。

## Flutter 与 Dart 包

Flutter / Dart 保留其 BSD 许可；Cupertino Icons 为 MIT，Material Icons 为 Apache-2.0。Dio、PointyCastle、media_kit、flutter_inappwebview、flutter_secure_storage、文件选择/打开/分享、托盘及窗口插件等的准确版本记录于 pubspec.lock。其许可由 Flutter 收集并随构建保留；0.3.31 暂时移除应用内的“开源许可”菜单入口。

vendor_plugins/ 中保留三项插件及 media_kit 的源码和原许可。Android media 插件使用当前 AGP 与 compileSdk，依赖下载先尝试 GitHub，再使用加速地址，并保留固定校验、超时和临时文件处理；改动记录见 vendor_plugins/media_kit_libs_android_video/ASTERLINK_PATCHES.md。media_kit 1.2.6 补充读取 libmpv 的 demux-rotation 字段，改动与上游来源记录在 vendor_plugins/media_kit/ASTERLINK_PATCHES.md，MIT 许可保留在同目录 LICENSE。上述补丁不更换媒体 native 库。

## 媒体 native 组件

Android 使用 libmpv-android-video-build v1.1.7 的 default 构建；构建项目的原许可见 assets/licenses/media-native-build-LICENSE.txt。上游构建配置禁用 GPL flavor，保留 mpv、FFmpeg 和各依赖自身的适用许可。精确的构建脚本、依赖版本和补丁归档在 native/third_party/libmpv-android-build-v1.1.7.zip。

构建源码：https://github.com/media-kit/libmpv-android-video-build/tree/v1.1.7
mpv：https://github.com/mpv-player/mpv
FFmpeg：https://github.com/FFmpeg/FFmpeg

Windows 使用 media-kit/libmpv-win32-video-cmake 的 20241021 构建（mpv 0.39 开发快照）及 ANGLE v1.0.1，版本和校验值保留在 Windows media_kit 插件及 tool/prepare-windows-media.ps1 中。升级记录见 vendor_plugins/media_kit_libs_windows_video/ASTERLINK_PATCHES.md。

Windows mpv 构建源码：https://github.com/media-kit/libmpv-win32-video-cmake
ANGLE 构建源码：https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/tree/v1.0.1

## Android NDK / Jetpack

Gopeed AAR 附带 NDK 28.2.13676358 的 libc++_shared.so。LLVM 及附带组件的完整 NOTICE 位于 assets/licenses/android-ndk-NOTICE.txt，也保留在 AAR 的 META-INF/licenses/ 中。Android / Jetpack 组件保留各自的 Apache-2.0 等许可，具体依赖声明见 android/app/build.gradle.kts 与各插件构建文件。

## 字幕字体

播放器优先使用设备已有的中文字库。系统缺少可用中文字库时，按需下载并缓存 Noto Sans SC Regular，来自 notofonts/noto-cjk 的 Sans/SubsetOTF/SC/NotoSansSC-Regular.otf，固定于 Sans2.004 对应提交 523d033d6cb47f4a80c58a35753646f5c3608a78。使用 SIL Open Font License 1.1，完整许可位于 assets/licenses/NotoSansCJK-OFL.txt。备用字体仅供原生字幕渲染使用，没有改动原始字体；安装包不再附带这份完整字库。

上游：https://github.com/notofonts/noto-cjk

字体 SHA-256：faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9

## 图标

各网盘标识来自用户提供的原工程与参考资源，归相应服务提供者所有，不代表官方客户端或合作关系。文析助手自 0.3.30 起采用用户提供的 `UI/图标.jpeg` 云朵、文档、放大镜与下载箭头图案，按平台生成透明边缘、压缩尺寸、自适应及单色主题资源；原始图片保留在工程中。界面测试使用本机字体生成图片，源码和应用不打包 Windows 系统字体文件。

0.3.14 曾采用用户提供的 `UI/图标.zip`；0.3.19 按用户新要求重绘为链环、云朵、下载托盘和人物轮廓，保存于 `assets/navigation/` 并按主题着色。SVG 渲染使用 flutter_svg 2.3.0 及 vector_graphics，相关包的许可由 Flutter 构建工具收录到应用许可列表。
