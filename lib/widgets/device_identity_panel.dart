import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../security/device_identity.dart';
import '../security/platform_identity_vault.dart';
import '../security/network_identity_auth.dart';

/// DEV5A: local enrollment + manually triggered mutual network identity proof.
/// Legacy file transfer still uses UNENCRYPTED HTTP and is NOT authorized here.
class DeviceIdentityPanel extends StatefulWidget {
  const DeviceIdentityPanel({super.key});

  @override
  State<DeviceIdentityPanel> createState() => _DeviceIdentityPanelState();
}

class _DeviceIdentityPanelState extends State<DeviceIdentityPanel> {
  final DeviceIdentityManager manager = DeviceIdentityManager(const PlatformIdentityVault());
  final TextEditingController cardController = TextEditingController();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController fingerprintController = TextEditingController();
  final TextEditingController remoteIpController = TextEditingController();
  late final IdentityProofServer proofServer = IdentityProofServer(manager);
  String? selectedRemoteFingerprint;
  String proofStatus = '尚未发起联网身份认证';
  bool proofBusy = false;
  String? proofServerError;
  bool loading = true;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await manager.initialize();
      if (!mounted) return;
      try {
        await proofServer.start();
      } catch (e) {
        proofServerError = '联网认证监听未启动：$e';
      }
      if (!mounted) return;
      setState(() { loading = false; error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = '$e'; });
    }
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pasteCard() async {
    final data = await Clipboard.getData('text/plain');
    if (!mounted) return;
    if (data?.text == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('剪贴板没有可用文本')));
      return;
    }
    setState(() => cardController.text = data!.text!);
  }

  Future<void> _register() async {
    if (busy) return;
    final cardInput = cardController.text.trim();
    final name = nameController.text.trim();
    final typedFingerprint = fingerprintController.text.trim().toLowerCase();
    PublicIdentityCard card;
    try {
      card = PublicIdentityCard.parse(cardInput);
      if (name.isEmpty) throw const FormatException('请填写设备备注名称');
      if (typedFingerprint != card.fingerprint) {
        throw const FormatException('完整指纹不一致。请在对方设备上独立读取并核对完整 64 位指纹。');
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认登记设备身份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('备注：$name'),
            const SizedBox(height: 10),
            const Text('完整身份指纹：'),
            SelectableText(card.fingerprint, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 12),
            const Text('确认你已亲自在另一台设备的“本机身份”页面核对以上全部 64 个十六进制字符。\n\n本次只是登记公钥，不代表当前 HTTP 传输已经得到认证或加密。',
                style: TextStyle(fontSize: 13, height: 1.5)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('已核对，登记')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => busy = true);
    try {
      await manager.register(
        displayName: name,
        identityCard: cardInput,
        independentlyCheckedFingerprint: typedFingerprint,
      );
      if (mounted) {
        cardController.clear();
        nameController.clear();
        fingerprintController.clear();
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('身份公钥已登记；网络连接尚未进行密码学认证')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('登记失败：$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _revoke(RegisteredIdentity item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销身份登记？'),
        content: Text('将撤销“${item.name}”的本地公钥记录，不删除原有文件或传输历史。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('撤销登记')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    try {
      await manager.revoke(item.fingerprint);
      if (mounted) setState(() {
        if (selectedRemoteFingerprint == item.fingerprint) selectedRemoteFingerprint = null;
        proofStatus = '身份登记已撤销，下一次签名验证将拒绝该设备。';
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('撤销失败：$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _tryNetworkProof() async {
    if (proofBusy) return;
    final index = manager.entries.indexWhere((e) => e.fingerprint == selectedRemoteFingerprint);
    if (index < 0) {
      setState(() => proofStatus = '请先在两端互相登记身份，并选择需要验证的设备。');
      return;
    }
    setState(() { proofBusy = true; proofStatus = '正在验证双方签名……'; });
    try {
      final result = await IdentityProofClient(manager).verify(
        remoteIp: remoteIpController.text.trim(),
        target: manager.entries[index],
      );
      if (mounted) setState(() {
        proofStatus = '本次联网身份签名验证通过：${result.fingerprint}。但文件传输仍未加密。';
      });
    } catch (e) {
      if (mounted) setState(() { proofStatus = '联网身份认证未通过：$e'; });
    } finally {
      if (mounted) setState(() => proofBusy = false);
    }
  }

  @override
  void dispose() {
    cardController.dispose();
    nameController.dispose();
    fingerprintController.dispose();
    remoteIpController.dispose();
    unawaited(proofServer.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(colors: [Color(0x333D7D82), Color(0x141A3440)]),
        border: Border.all(color: const Color(0x88B8F2EE), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.verified_user_outlined, color: Color(0xFF74D9D2)),
            SizedBox(width: 10),
            Expanded(child: Text('设备身份与登记 · DEV5A', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17))),
          ]),
          const SizedBox(height: 10),
          const Text('DEV5A 增加了独立联网签名认证测试。旧文件仍经未加密 HTTP 传输，认证通过也不授予文件接收权限。',
              style: TextStyle(color: Color(0xFFF2B84B), height: 1.5, fontSize: 12.5)),
          const SizedBox(height: 14),
          if (loading) const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())),
          if (error != null) ...[
            const Text('设备密钥读取失败，已停止自动生成/覆盖。', style: TextStyle(color: Color(0xFFFFB89C))),
            const SizedBox(height: 8),
            SelectableText(error!, style: const TextStyle(fontSize: 12)),
          ],
          if (!loading && error == null) ...[
            const Text('本机身份指纹（64 位 SHA-256）', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SelectableText(manager.local.fingerprint,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.5)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () => _copy(manager.local.fingerprint, '本机完整指纹已复制'),
                icon: const Icon(Icons.copy_rounded),
                label: const Text('复制指纹'),
              ),
              OutlinedButton.icon(
                onPressed: () => _copy(manager.local.card, '公钥身份卡已复制（不含私钥）'),
                icon: const Icon(Icons.badge_outlined),
                label: const Text('复制身份卡'),
              ),
            ]),
            const SizedBox(height: 14),
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(
                  data: manager.local.card,
                  version: QrVersions.auto,
                  size: 174,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Center(child: Text('公钥身份卡二维码（不包含私钥）',
                style: TextStyle(fontSize: 12, color: Color(0xFFA9C0C3)))),
            const Divider(height: 28),
            const Text('登记另一台设备', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            const Text('将对方的身份卡文本粘贴到下面；再独立查看对方屏幕上的完整指纹并输入。当前不支持 App 内扫码，可用系统相机扫描二维码后复制文本。',
                style: TextStyle(fontSize: 12, color: Color(0xFFA9C0C3), height: 1.5)),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              maxLength: 40,
              decoration: const InputDecoration(labelText: '设备备注名称', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: cardController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: '对方身份卡（LINYUE-ID1:...）',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(onPressed: _pasteCard, tooltip: '粘贴', icon: const Icon(Icons.content_paste_rounded)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: fingerprintController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '从对方屏幕独立核对并输入的完整 64 位指纹',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : _register,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('核对并登记设备身份'),
            ),
            const SizedBox(height: 16),
            Text('本地登记（${manager.entries.length}）', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (manager.entries.isEmpty)
              const Text('暂无登记记录', style: TextStyle(color: Color(0xFFA9C0C3)))
            else
              ...manager.entries.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x1C7BDFD6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x4474D9D2)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                      IconButton(
                        onPressed: busy ? null : () => _revoke(item),
                        tooltip: '撤销身份登记',
                        icon: const Icon(Icons.person_remove_outlined),
                      ),
                    ]),
                    SelectableText(item.fingerprint, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                    const Text('身份已登记 · 待联网签名认证 · 文件传输仍未加密',
                        style: TextStyle(fontSize: 11, color: Color(0xFFF2B84B))),
                  ]),
                ),
              )),
            const Divider(height: 32),
            const Row(children: [
              Icon(Icons.security_rounded, size: 20, color: Color(0xFF74D9D2)),
              SizedBox(width: 8),
              Expanded(child: Text('DEV5A · 联网身份签名验证', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
            const Text(
              '先在两台设备相互登记公钥，再同时打开两端的设置页面。使用对方局域网 IP 发起签名验证。此操作不会启用加密文件传输。',
              style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 12.5, height: 1.6),
            ),
            const SizedBox(height: 10),
            Text(proofServer.running
                ? '身份验证监听已启动 · TCP ${proofServer.port}（仅在本设置页打开时运行）'
                : (proofServerError ?? '身份验证监听尚未启动'),
                style: const TextStyle(color: Color(0xFFF2B84B), fontSize: 12)),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: selectedRemoteFingerprint,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '选择已登记的对方设备', border: OutlineInputBorder()),
              items: manager.entries.map((e) => DropdownMenuItem<String>(
                value: e.fingerprint,
                child: Text(e.name, overflow: TextOverflow.ellipsis),
              )).toList(),
              onChanged: proofBusy ? null : (value) => setState(() => selectedRemoteFingerprint = value),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: remoteIpController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '对方 IPv4 地址（如 192.168.1.6）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: proofBusy || manager.entries.isEmpty ? null : _tryNetworkProof,
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('验证本次双方身份签名'),
            ),
            const SizedBox(height: 8),
            SelectableText(proofStatus,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFFF2B84B), height: 1.6)),
            const SizedBox(height: 8),
            const Text('警告：旧 TCP 46729 文件传输仍为未加密 HTTP。DEV5A 不提供加密会话，也不会授权旧的明文文件请求。',
                style: TextStyle(color: Color(0xFFF2B84B), fontSize: 12, height: 1.5)),
          ],
        ],
      ),
    );
  }
}
