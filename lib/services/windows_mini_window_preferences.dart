import 'dart:convert';
import 'dart:io';

import 'windows_mini_window_bridge.dart';

/// Windows-only presentation preferences; contains no message text, device
/// identity, paths, file content, network keys, or app encryption secrets.
class MiniWindowPreferences {
  MiniWindowPreferences(this.directory);

  final Directory directory;

  File get _file => File('${directory.path}${Platform.pathSeparator}mini_window_v1.json');
  File get _backup => File('${_file.path}.bak');
  File get _temp => File('${_file.path}.tmp');

  static const defaultPreset = 'medium';
  static const maxFileBytes = 4096;

  Future<MiniWindowPreference> load() async {
    for (final f in <File>[_file, _backup]) {
      try {
        if (!await f.exists() || await f.length() > maxFileBytes) continue;
        final decoded = jsonDecode(await f.readAsString());
        final pref = MiniWindowPreference.fromJson(decoded);
        if (pref != null) return pref;
      } catch (_) {
        // Damaged preferences should never affect secure history or startup.
      }
    }
    return const MiniWindowPreference();
  }

  Future<void> save(MiniWindowPreference preference) async {
    await directory.create(recursive: true);
    final json = jsonEncode(preference.toJson());
    if (json.length > maxFileBytes) throw const FormatException('Window preferences too large');
    await _temp.writeAsString(json, flush: true);
    // On Windows a rename over an existing destination is not guaranteed.
    // Keep last committed settings as a readable backup across the swap.
    if (await _backup.exists()) await _backup.delete();
    if (await _file.exists()) await _file.rename(_backup.path);
    try {
      await _temp.rename(_file.path);
    } catch (_) {
      if (await _backup.exists() && !await _file.exists()) {
        await _backup.rename(_file.path);
      }
      rethrow;
    }
  }
}

class MiniWindowPreference {
  const MiniWindowPreference({
    this.preset = MiniWindowPreferences.defaultPreset,
    this.saved,
  });

  final String preset;
  final MiniWindowSnapshot? saved;

  bool get pinned => saved?.pinned ?? false;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'preset': preset,
    'saved': saved?.toJson(),
  };

  static MiniWindowPreference? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['version'] != 1 || raw['preset'] is! String) return null;
    final preset = raw['preset'] as String;
    if (!MiniWindowSnapshot.presets.contains(preset)) return null;
    final data = raw['saved'];
    if (data != null && data is! Map) return null;
    final saved = data == null ? null : MiniWindowSnapshot.fromMap(data);
    if (data != null && saved == null) return null;
    // A stale snapshot for another tier is ignored, not applied.
    return MiniWindowPreference(
      preset: preset, saved: saved?.preset == preset ? saved : null,
    );
  }

  @override
  bool operator ==(Object other) => other is MiniWindowPreference &&
      other.preset == preset && other.saved == saved;

  @override
  int get hashCode => Object.hash(preset, saved);
}
