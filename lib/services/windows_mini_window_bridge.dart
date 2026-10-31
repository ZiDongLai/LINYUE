import 'dart:io';

import 'package:flutter/services.dart';

/// Non-sensitive native HWND geometry. Coordinates are physical Windows px;
/// native code clamps them onto a currently connected monitor on restoration.
class MiniWindowSnapshot {
  const MiniWindowSnapshot({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.pinned,
    required this.preset,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final bool pinned;
  final String preset;

  static const presets = {'small', 'medium', 'large'};

  bool get isValid =>
      presets.contains(preset) &&
      x.abs() <= 1000000 && y.abs() <= 1000000 &&
      width >= 300 && width <= 3000 &&
      height >= 330 && height <= 3000;

  Map<String, Object> toJson() => <String, Object>{
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'pinned': pinned,
    'preset': preset,
  };

  static MiniWindowSnapshot? fromMap(Map<dynamic, dynamic>? map) {
    if (map == null || map['x'] is! int || map['y'] is! int ||
        map['width'] is! int || map['height'] is! int ||
        map['pinned'] is! bool || map['preset'] is! String) return null;
    final snapshot = MiniWindowSnapshot(
      x: map['x'] as int, y: map['y'] as int,
      width: map['width'] as int, height: map['height'] as int,
      pinned: map['pinned'] as bool, preset: map['preset'] as String,
    );
    return snapshot.isValid ? snapshot : null;
  }

  @override
  bool operator ==(Object other) => other is MiniWindowSnapshot &&
      other.x == x && other.y == y &&
      other.width == width && other.height == height &&
      other.pinned == pinned && other.preset == preset;

  @override
  int get hashCode => Object.hash(x, y, width, height, pinned, preset);
}

/// Controls the ONE Flutter Windows HWND. Does not create a new engine.
class WindowsMiniWindowBridge {
  WindowsMiniWindowBridge({MethodChannel? channel, bool? isWindows})
      : _channel = channel ?? const MethodChannel('nearlink/mini_window'),
        _isWindows = isWindows ?? Platform.isWindows;

  final MethodChannel _channel;
  final bool _isWindows;

  Future<bool> enterMini({
    String preset = 'medium',
    MiniWindowSnapshot? saved,
  }) {
    if (!MiniWindowSnapshot.presets.contains(preset)) return Future.value(false);
    final args = <String, Object>{'preset': preset};
    if (saved != null && saved.isValid && saved.preset == preset) {
      args.addAll({
        'x': saved.x, 'y': saved.y,
        'width': saved.width, 'height': saved.height,
      });
    }
    return _invoke('enterMini', args);
  }

  Future<bool> resizeMini(String preset) =>
      MiniWindowSnapshot.presets.contains(preset)
          ? _invoke('resizeMini', <String, Object>{'preset': preset})
          : Future.value(false);

  Future<MiniWindowSnapshot?> getSnapshot() async {
    if (!_isWindows) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getMiniState');
      if (result == null || result['mini'] != true) return null;
      return MiniWindowSnapshot.fromMap(result);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> restoreMain() => _invoke('restoreMain');
  Future<bool> setTopmost(bool value) =>
      _invoke('setTopmost', <String, Object>{'enabled': value});

  Future<bool> _invoke(String method, [Object? args]) async {
    if (!_isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>(method, args) == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
