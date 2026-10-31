/// D4-A: read-only timings for diagnosing delayed LAN discovery.
///
/// This class never authenticates peers and never initiates socket traffic.
/// Timestamps must come from one monotonic Stopwatch started with discovery.
enum DiscoveryTraceSource { udpHello, healthProbe }

class DiscoveryLatencyTrace {
  int? firstBroadcastAttemptMs;
  int? firstBroadcastSuccessMs;
  int? firstDatagramMs;
  int? firstValidHelloMs;
  int? firstVisiblePeerMs;
  DiscoveryTraceSource? firstVisibleSource;
  int broadcastAttempts = 0;
  int broadcastAccepted = 0;
  int datagramsSeen = 0;

  void onBroadcast(int elapsedMs, {required bool accepted}) {
    if (elapsedMs < 0) return;
    broadcastAttempts++;
    firstBroadcastAttemptMs ??= elapsedMs;
    if (accepted) {
      broadcastAccepted++;
      firstBroadcastSuccessMs ??= elapsedMs;
    }
  }

  void onDatagram(int elapsedMs) {
    if (elapsedMs < 0) return;
    datagramsSeen++;
    firstDatagramMs ??= elapsedMs;
  }

  void onValidHello(int elapsedMs) {
    if (elapsedMs < 0) return;
    firstValidHelloMs ??= elapsedMs;
  }

  void onPeerVisible(int elapsedMs, {required DiscoveryTraceSource via}) {
    if (elapsedMs < 0 || firstVisiblePeerMs != null) return;
    firstVisiblePeerMs = elapsedMs;
    firstVisibleSource = via;
  }

  String summary(int elapsedMs) {
    String display(int? value) => value == null ? '未发生' : '${value}ms';
    final source = switch (firstVisibleSource) {
      DiscoveryTraceSource.udpHello => 'UDP',
      DiscoveryTraceSource.healthProbe => 'TCP健康探测',
      null => '无',
    };
    return '运行${elapsedMs}ms；广播首发${display(firstBroadcastAttemptMs)}'
        '／送出${display(firstBroadcastSuccessMs)}'
        '（$broadcastAccepted/$broadcastAttempts）；'
        '首个UDP包${display(firstDatagramMs)}（收包$datagramsSeen）；'
        '首个有效hello${display(firstValidHelloMs)}；'
        '首个可见设备${display(firstVisiblePeerMs)}（$source，未认证）';
  }
}
