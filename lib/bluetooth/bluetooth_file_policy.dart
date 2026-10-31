/// E38 local default. The 1 MiB E36 wire capability remains the safe fallback.
const bluetoothStableFileBytes = 1024 * 1024;
const bluetoothDefaultFileBytes = 10 * 1024 * 1024;
// Retained E37 API name; the negotiated extension is now the E38 default.
const bluetoothCandidateFileBytes = bluetoothDefaultFileBytes;
int bluetoothBuildFileLimit() => bluetoothDefaultFileBytes;
bool bluetoothValidFileLimit(int value) =>
    value == bluetoothStableFileBytes || value == bluetoothCandidateFileBytes;
String bluetoothFileLimitLabel(int value) => '${value ~/ (1024 * 1024)} MiB';
