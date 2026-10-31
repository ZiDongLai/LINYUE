/// Known internal checkpoint/receipt names are never completed user files.
/// Keep LAN naming and storage unchanged; only filter the completed-file view.
bool isCompletedReceivedName(String name) {
  final lower = name.toLowerCase();
  return !lower.startsWith('.linyue_part_') &&
      !lower.contains('.part.') &&
      !RegExp(
        r'^\.linyue_resume_(?:v2_)?[a-f0-9]{32}\.(?:part|[ab]\.json|receipt\.json(?:\.tmp\.\d+)?)$',
      ).hasMatch(lower);
}
