# 邻跃 LINYUE

Windows 与 Android 间的局域网与经典蓝牙通信工具，使用 Flutter、Kotlin 和 C++。

当前版本：**v0.5.67+51**（2026-11-16）。Windows 程序文件名为 `linyue.exe`。本版改善同网段设备搜索，加入 Windows 电脑间蓝牙等待连接入口，移除蓝牙界面的测试版描述，并修复 Windows 大文件入队时的磁盘空间查询失败。

## 下载

[Windows 安装与连接说明](docs/INSTALL_WINDOWS.md)

当前完整 Windows 包对应 `v0.5.67+51`，仅保存在维护者本地的 `dist/` 目录；GitHub 源码仓库不存放大型构建包。GitHub Release 附件仍是 v0.5.65 历史版本。

[v0.5.65 Debug 预发布与安装说明](https://github.com/ZiDongLai/LINYUE/releases/tag/v0.5.65-debug)

- [历史 Windows Debug ZIP（未包含本次修正）](https://github.com/ZiDongLai/LINYUE/releases/download/v0.5.65-debug/windows_v0.5.65_DEV13D2E38_stability_debug.zip)：其中程序依赖调试版 MSVC DLL；没有 Visual Studio C++ 调试环境的电脑无法启动，不要用于新电脑部署。
- [历史 Android APK v0.5.65](https://github.com/ZiDongLai/LINYUE/releases/download/v0.5.65-debug/android_v0.5.65_DEV13D2E38_stability_debug.apk)：不是本次 v0.5.67 构建；本次环境没有 Android SDK，尚未生成新版 APK。
- [SHA-256 校验文件](https://github.com/ZiDongLai/LINYUE/releases/download/v0.5.65-debug/SHA256SUMS.txt)。

该 GitHub Release 标为 **Pre-release**，不是新的生产 Release 构建。

## 现有功能

- 首页统一连接、文字输入和“＋”文件入口，使用当前明确选择的LAN或蓝牙通道。
- 设备配对、身份认证、加密文字与文件传输；文件校验与最终保存确认。
- 蓝牙双向单文件最多10MiB，以双方实际协商能力为准；失败不会静默切换LAN。
- 接收历史、打开、保存、Android分享及“用其他应用打开”、Windows迷你聊天窗等既有操作。
- LAN保留原有文件传输与恢复能力；**蓝牙断点续传暂停，未交付**。

蓝牙连接在 Debug 构建中开放。Windows 扫描附近经典蓝牙设备及已配对设备；未配对设备需先到系统设置完成配对。电脑间连接时，接收端点击“等待另一台电脑连接”，发起端选择对端。实际两台 Windows 电脑互连仍需在蓝牙硬件上验收；约10分钟会话寿命不变，蓝牙断点续传暂停，未交付。

Windows 在启动时会自动对当前小型私有 IPv4 子网做一次有界健康探测，最多检查 1022 个地址；首页刷新按钮也可重新搜索。局域网设备搜索只用于定位，不会自动授权或认证设备。跨 VLAN、访客网络或被防火墙隔离时，仍需同网段可达；首次运行时允许 Windows 防火墙在“专用网络”通信。双手机 LAN 尚缺第二台真机验收，不开发手机间蓝牙。

## 开发环境与命令

本轮已验证环境：Flutter **3.47.7** / Dart **3.13.5**；Windows构建需要兼容的Visual Studio C++桌面开发工具，Android构建需要Android SDK和Java 17或工程工具链兼容的JDK。保留 `pubspec.lock`，首次拉取在此仓库根目录执行：

```powershell
flutter doctor -v
flutter pub get
flutter test --concurrency 1 --fail-fast
flutter analyze
flutter build windows --debug
flutter build apk --debug
```

本项目已有完整平台代码，**不要用 `flutter create` 重建工程，也无需旧版初始化脚本**。`flutter pub get` 会生成本机SDK及插件相关配置。Windows Debug 构建保留开发版功能，但已配置为不依赖 `MSVCP140D.dll` 等调试运行库。分发时需保留完整运行目录，不能只分发 EXE；用 `flutter build windows --debug` 重新构建并打包整个 Windows 输出目录。

进行端口相关测试前正常退出正在运行的邻跃（含迷你窗）。`qa/` 为可选历史压力/大文件测试，不在普通全量 `test/` 结果中，不默认执行。不要把LAN压力测试解释成蓝牙大文件支持。

## 验证与交付

本版验证结果与尚未执行的设备验收见 [验证记录](docs/VALIDATION.md)。Android SDK 当前不在本次构建环境中，因此没有为本版生成新 APK；`dist/` 中旧版本 APK 不属于 v0.5.67。

Android签名密钥、设备身份密钥、用户历史和原始设备日志均不入库。在新电脑自行构建得到的Debug签名不保证与用户已安装APK相同；不得靠卸载或清数据绕过更新失败。[构建与发布边界](docs/RELEASE_CHECKLIST.md)说明后续正式发行所需事项。

## 源码范围

本仓库从已冻结源码包建立，生产、测试、依赖锁定和原生实现保持原字节。根目录已统一为本冻结版；旧E40实验源码只保留一份本地回退压缩包，旧历史目录按用户清理要求删除，不混入此提交。内部独立P0原语保留，不代表蓝牙续传已接入。

## 许可

项目尚未指定开源许可证；此次准备不擅自授予开源许可。第三方依赖继续遵循其各自许可证。公开仓库可见性与选择开源许可证须分别决定。

## 当前目录

- `lib/`、`android/`、`windows/`：当前软件源码和平台工程。
- `test/`、`qa/`：回归测试与可选历史压力测试；`scripts/`：仍适用的测试文件和摘要工具。
- `docs/`：使用、验证、发布边界及本次清理记录。
- `dist/`：Windows完整ZIP、历史Android APK、原冻结源码ZIP与SHA-256；仅本地保留，不提交Git。
- `.recovery/`：仅本地的一份旧实验源码备份、本版验证证据和清理日志，不提交Git。

现有项目根目录即维护与Git入口，不再需要进入隐藏的重复工程目录。清理没有改变软件业务、依赖或版本，也未重新构建已验收包。
