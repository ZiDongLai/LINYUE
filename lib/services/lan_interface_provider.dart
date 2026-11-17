import 'dart:io';

import 'package:flutter/services.dart';

import 'discovery_active_probe_policy.dart';

/// Native interface prefixes are required to keep discovery on local subnets.
Future<List<LanInterfaceSnapshot>> loadLanInterfaces() async {
  if (!(Platform.isWindows || Platform.isAndroid)) return const [];
  final rows = await const MethodChannel(
    'nearlink/network_discovery',
  ).invokeListMethod<Object?>('getInterfaces');
  return [
    for (final row in rows ?? const <Object?>[])
      if (row is Map && row['address'] is String && row['prefixLength'] is int)
        LanInterfaceSnapshot(
          address: row['address'] as String,
          prefixLength: row['prefixLength'] as int,
        ),
  ];
}
