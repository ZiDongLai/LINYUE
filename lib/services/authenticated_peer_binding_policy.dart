/// Display/session binding rules after the existing signed pairing protocol has
/// authenticated a remote fingerprint. These rules never establish trust.
final class AuthenticatedPeerBindingPolicy {
  const AuthenticatedPeerBindingPolicy._();

  /// If discovery did not create a peer card for this authenticated endpoint,
  /// the caller may create a manual locator for the same source IP.
  static bool shouldCreateManualLocator({
    required Iterable<String> knownPeerIps,
    required String authenticatedRemoteIp,
  }) => !knownPeerIps.contains(authenticatedRemoteIp);

  /// Do not steal a conversation the user explicitly selected for another IP.
  /// An empty selection or the same endpoint may follow the completed pairing.
  static bool shouldSelectPeer({
    required String? activePeerIp,
    required String remoteIp,
  }) => activePeerIp == null || activePeerIp == remoteIp;
}
