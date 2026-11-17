# 已冻结版本验证记录

基线：v0.5.65 DEV13D2E38 / 0.5.65+49；记录日期：2026-10-31。

| 验证 | 结果 | 退出码 |
|---|---|---:|
| Flutter定向 | 67 PASS，与全量重叠 | 0 |
| Flutter全量test目录 | 1025 PASS，0失败/跳过 | 0 |
| 原生契约（宿主） | 17 PASS | 0 |
| Windows文件提交 | 34 PASS | 0 |
| Java宿主文件提交 | 32 PASS | 0 |
| Windows Debug构建 | 成功 | 0 |
| Android Debug构建 | 成功 | 0 |
| 静态分析 | 基线与候选均237条（26 WARNING、211 INFO），新增0 | 2 |
| Windows↔Mate60人工验收 | 用户整体回复“测试通过，继续下一步。”；未补填逐项耗时或新日志 | 不适用 |

数据来自冻结交付档案，不是本次GitHub准备重新测试的结果。Java宿主测试不代替Android真机；设备验收范围仅当前电脑与Mate60。

本版自动化过程中的报告脚本中断和Windows夹具目录碰撞证据，随当前验证记录压缩保存在本地.recovery/current_0.5.65_validation_evidence.zip。更早的大量历史审计、旧包和故障现场按用户本次明确清理指令删除，不再宣称历史归档可完整还原；此前登记的四份E34模拟诊断原始字节缺失也没有恢复。GitHub不上传这些内部证据。

当前保留限制：局域网历史偶发发现延时、Debug限定蓝牙、约10分钟会话、双手机LAN待验。未宣称公开发行已就绪或已实现蓝牙续传。

## 2026-11-15 Windows 部署修正

| 验证 | 结果 |
|---|---|
| Windows Debug 构建 | 成功；输出 `linyue.exe` |
| MSVC 依赖检查 | 主程序、Flutter 插件及运行库未导入 `MSVCP140D.dll`、`VCRUNTIME140D.dll` 或 `ucrtbased.dll` |
| 完整包检查 | ZIP 含主程序、Flutter 运行库、插件 DLL、MSVC 可再发行运行库及 `data` 资源；无旧名 EXE 或 PDB |
| ZIP 完整性 | 可读取；必需文件检查通过 |

本地交付包：`dist/windows_v0.5.65_DEV13D2E38_stability_debug_linyue.zip`。SHA-256：`972E4A927287423D90EC89509B9A4825F84929AE269CCF0237DF4476DAB45264`。本次只重建并检查 Windows Debug 包，未重新运行全量 Flutter 测试，也未上传或替换 GitHub Release 附件。

## 2026-11-16 局域网与蓝牙搜索修正

版本：`0.5.66+50`；Windows 产物名称：`linyue.exe`。

| 验证 | 结果 |
|---|---|
| Flutter 全量测试 | 1147 个测试通过，0 失败 |
| LAN 自动发现与 socket 生命周期定向测试 | 16 个测试通过，包含启动自动探测、子网边界、跨接口全局上限及生命周期 |
| 蓝牙 UI、扫描与身份流程定向测试 | 44 个测试通过 |
| Windows Debug 构建 | 成功，输出 `build/windows/x64/runner/Debug/linyue.exe` |
| Windows ZIP 检查 | 28 项；包含 EXE、Flutter DLL、MSVC 可再发行运行库、完整 `data` 目录和安装说明；无 PDB、无 `nearlink.exe` |
| Dart 静态分析 | 254 条提示（26 warning、228 info），退出码 1；修改涉及的搜索与蓝牙 Dart 模块共 8 条 `info` 格式提示，无分析错误 |
| Windows 双机 LAN/蓝牙硬件验收 | 未完成；当前构建机未进行两台实体电脑互连 |
| Android Debug 构建 | 未执行；本次环境未配置 Android SDK/JDK |

首次生成的 Windows 完整包：`dist/linyue_windows_v0.5.66_20261116.zip`。其 SHA-256 为 `DA18DEA3E016E323F30BC958D668BA80E423C6787F00C93F11DD684D0384ABBB`；该包已由下方的磁盘空间修复包替换。

局域网自动探测限制为当前 RFC1918 小型子网、所有网卡合计最多 1022 个地址、最多 48 个并发请求；结果只用于设备定位，不授予身份信任。电脑间蓝牙需先在 Windows 系统设置完成配对，接收端启动 RFCOMM 等待服务。硬件互连仍需实机验证。

## 2026-11-16 Windows 磁盘空间查询修复

文件大于 20 MiB 时，加入发送队列前会先准备可恢复副本并查询 Windows 磁盘空间。Windows 插件原先逐字节扩展路径字符串，含中文等非 ASCII 字符的用户目录可能因此查询失败；这与文件扩展名无关。现由应用原生通道以 UTF-8 解码路径，再调用 `GetDiskFreeSpaceExW` 查询目标卷。

| 验证 | 结果 |
|---|---|
| 磁盘空间检查器定向测试 | 12 项通过，包含中文 Windows 路径传递 |
| Flutter 全量测试 | 1030 项通过，0 失败 |
| 修改模块 Dart 分析 | 0 warning/error；3 条既有 style info |
| Windows 原生路径探测 | 在含中文产品目录的应用支持目录上调用 `GetDiskFreeSpaceExW` 成功 |
| Windows Debug 构建 | 成功，输出 `linyue.exe` |
| 完整 ZIP | 28 项；必需 EXE、资源和说明齐全，无 PDB |

首次修复版 Windows 完整包：`dist/linyue_windows_v0.5.66_20261116.zip`。SHA-256：`C64DFFB0DF6327A4202CC52BD8C5AABF18CB33F29748C4E4A16785AAB327E242`；现由 v0.5.67+51 包替换。

## 2026-11-16 大文件入队修复版 v0.5.67+51

超过 20 MiB 的文件不区分扩展名，都会进入断点续传暂存流程并查询应用支持目录所在卷。本版修复 Windows 中文路径查询，并在查询仍失败时把 Win32 错误码带入提示，便于定位具体电脑上的访问或路径问题。此前提供的完整窗口截图显示运行版本为 v0.5.65；本次完整包使用 `0.5.67+51`，可在文件属性中核对版本。

| 验证 | 结果 |
|---|---|
| 磁盘空间检查器定向测试 | 13 项通过，覆盖 Unicode 路径传递与查询失败原因保留 |
| Flutter 全量测试 | 1031 项通过，0 失败 |
| 修改模块 Dart 分析 | 0 warning/error；3 条 info |
| Windows 原生路径探测 | 含中文产品目录的应用支持目录可成功调用 `GetDiskFreeSpaceExW` |
| Windows Debug 构建 | 成功；EXE 文件版本为 `0.5.67+51` |
| 完整 ZIP | 28 项；必需 EXE、资源和安装说明齐全，无 PDB；归档读取校验通过 |

当前 Windows 完整包：`dist/linyue_windows_v0.5.67_20261116.zip`。SHA-256：`8DCB0E7F67CA7A18CE54E487FD9EFC86C353E00B83C9ABB47E2A111D96062136`。该完整包仅保存在本地 `dist/` 目录，没有纳入 GitHub 源码仓库。Android APK 与 GitHub Release 未重建或替换；仍需用户在目标电脑运行此版本验证实际大文件传输。

## 2026-11-16 Android 局域网搜索更新 v0.5.68+52

| 验证 | 结果 |
|---|---|
| Flutter 全量测试 | 1034 项通过，0 失败 |
| Android 局域网接口定向测试 | 3 项通过；仅接受原生 IPv4 接口和前缀，公网、过宽子网及无效数据不会进入探测 |
| 修改模块 Dart 分析 | 0 warning/error；7 条既有 style info |
| Android Debug 构建 | 成功；包名 `com.nearlink.nearlink`，versionCode `52`，versionName `0.5.68` |
| APK 架构 | `arm64-v8a`、`armeabi-v7a`、`x86_64` |
| APK 签名 | Android Debug 签名，APK Signature Scheme v2；不是原 v0.5.64 签名的确认副本 |
| Android 真机安装与传输 | 未完成；当前未连接 Android 设备 |

本地 APK：`dist/linyue_android_v0.5.68_20261116_debug.apk`。SHA-256：`CB504A313824BF6C24A8564877E265B70C4094F881DB235F146B8F703697594D`。APK 未纳入 GitHub 源码仓库；提交包含对应源码、测试和安装说明。由于未找到原版 v0.5.64 调试签名，不能保证覆盖更新，安装器提示签名冲突时应保留旧应用及数据。
