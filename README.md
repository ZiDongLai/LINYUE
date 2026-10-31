# 邻跃 LINYUE

Windows 与 Android 间的局域网与经典蓝牙通信工具，使用 Flutter、Kotlin 和 C++。

当前冻结交付版本：**v0.5.65 DEV13D2E38 / 0.5.65+49（Debug）**。已收到用户对 Windows ↔ 华为 Mate 60 Pro 现有功能验收通过的反馈。源码上传与公开正式版发布是不同步骤；本仓库不将 Debug 构建称为公开 Release 成品。

## 下载

[v0.5.65 Debug 预发布与安装说明](https://github.com/ZiDongLai/LINYUE/releases/tag/v0.5.65-debug)

- [Windows 完整运行 ZIP](https://github.com/ZiDongLai/LINYUE/releases/download/v0.5.65-debug/windows_v0.5.65_DEV13D2E38_stability_debug.zip)：完整解压后运行，勿只复制EXE。
- [Android APK](https://github.com/ZiDongLai/LINYUE/releases/download/v0.5.65-debug/android_v0.5.65_DEV13D2E38_stability_debug.apk)：保留数据更新；若签名或版本不兼容，停止，不卸载清数据。
- [SHA-256 校验文件](https://github.com/ZiDongLai/LINYUE/releases/download/v0.5.65-debug/SHA256SUMS.txt)。

附件为原已验收的Debug包，未重新构建；该GitHub Release标为 **Pre-release**，不是新的生产Release构建。

## 现有功能

- 首页统一连接、文字输入和“＋”文件入口，使用当前明确选择的LAN或蓝牙通道。
- 设备配对、身份认证、加密文字与文件传输；文件校验与最终保存确认。
- 蓝牙双向单文件最多10MiB，以双方实际协商能力为准；失败不会静默切换LAN。
- 接收历史、打开、保存、Android分享及“用其他应用打开”、Windows迷你聊天窗等既有操作。
- LAN保留原有文件传输与恢复能力；**蓝牙断点续传暂停，未交付**。

蓝牙仍保留测试版标记和 Debug 限制，约10分钟会话寿命不变。双手机LAN尚缺第二台真机验收；不开发手机间蓝牙。局域网自动发现仍有历史偶发延时记录。

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

本项目已有完整平台代码，**不要用 `flutter create` 重建工程，也无需旧版初始化脚本**。`flutter pub get` 会生成本机SDK及插件相关配置。Windows需保留完整运行目录，不能只分发EXE。

进行端口相关测试前正常退出正在运行的邻跃（含迷你窗）。`qa/` 为可选历史压力/大文件测试，不在普通全量 `test/` 结果中，不默认执行。不要把LAN压力测试解释成蓝牙大文件支持。

## 验证与交付

冻结前记录：Flutter全量1025通过、定向67通过（与全量重叠），原生契约17/Windows文件提交34/Java宿主提交32通过；双端Debug构建成功。分析237条存量提示、新增0、退出码2，未宣称分析全绿。此为原冻结批次记录，上传准备未重复运行这些测试。详见 [验证记录](docs/VALIDATION.md)。

Android签名密钥、设备身份密钥、用户历史和原始设备日志均不入库。在新电脑自行构建得到的Debug签名不保证与用户已安装APK相同；不得靠卸载或清数据绕过更新失败。[构建与发布边界](docs/RELEASE_CHECKLIST.md)说明后续正式发行所需事项。

## 源码范围

本仓库从已冻结源码包建立，生产、测试、依赖锁定和原生实现保持原字节。根目录已统一为本冻结版；旧E40实验源码只保留一份本地回退压缩包，旧历史目录按用户清理要求删除，不混入此提交。内部独立P0原语保留，不代表蓝牙续传已接入。

## 许可

项目尚未指定开源许可证；此次准备不擅自授予开源许可。第三方依赖继续遵循其各自许可证。公开仓库可见性与选择开源许可证须分别决定。

## 当前目录

- `lib/`、`android/`、`windows/`：当前软件源码和平台工程。
- `test/`、`qa/`：回归测试与可选历史压力测试；`scripts/`：仍适用的测试文件和摘要工具。
- `docs/`：使用、验证、发布边界及本次清理记录。
- `dist/`：已验收的Windows完整ZIP、Android APK、原冻结源码ZIP与SHA-256；仅本地保留，不提交Git。
- `.recovery/`：仅本地的一份旧实验源码备份、本版验证证据和清理日志，不提交Git。

现有项目根目录即维护与Git入口，不再需要进入隐藏的重复工程目录。清理没有改变软件业务、依赖或版本，也未重新构建已验收包。
