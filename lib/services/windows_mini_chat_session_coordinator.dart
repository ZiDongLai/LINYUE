import 'package:flutter/foundation.dart';

/// DEV13D2E21-A: Windows mini-chat view state and shared-session guard.
///
/// This class never owns or starts a discovery service, TCP connection, secure
/// channel, file queue, key vault, chat draft, or history store. The EXISTING
/// TransferHome remains the single owner. This coordinator only mirrors a
/// trusted snapshot of that owner's current authenticated session.
enum MiniChatViewPhase { closed, visible, minimized }

@immutable
class MiniChatOwnerSnapshot {
  const MiniChatOwnerSnapshot({
    required this.peerId,
    required this.peerLabel,
    required this.authenticatedFingerprint,
    required this.peerDiscovered,
    required this.encryptedChannelReady,
    required this.identityEnrolled,
    required this.textHistoryAvailable,
    this.textSendBusy = false,
    this.queuedFileCount = 0,
  }) : assert(queuedFileCount >= 0);

  /// Discovery ID and display label are NOT cryptographic identity.
  final String? peerId;
  final String? peerLabel;
  final String? authenticatedFingerprint;
  final bool peerDiscovered;
  final bool encryptedChannelReady;
  final bool identityEnrolled;
  final bool textHistoryAvailable;
  final bool textSendBusy;
  final int queuedFileCount;

  /// The owner must populate identityEnrolled using the trusted key vault and
  /// authenticatedFingerprint using the verified, paired session, NOT from
  /// an unauthenticated discovery packet or cached display name.
  bool get hasAuthenticatedRecipient =>
      peerDiscovered &&
      identityEnrolled &&
      encryptedChannelReady &&
      (peerId?.trim().isNotEmpty ?? false) &&
      (authenticatedFingerprint?.trim().isNotEmpty ?? false);

  bool get canSendText =>
      hasAuthenticatedRecipient && textHistoryAvailable && !textSendBusy;

  bool get canAddFile => hasAuthenticatedRecipient;

  bool get hasBoundIdentity =>
      (peerId?.trim().isNotEmpty ?? false) &&
      (authenticatedFingerprint?.trim().isNotEmpty ?? false);

  static const disconnected = MiniChatOwnerSnapshot(
    peerId: null,
    peerLabel: null,
    authenticatedFingerprint: null,
    peerDiscovered: false,
    encryptedChannelReady: false,
    identityEnrolled: false,
    textHistoryAvailable: false,
  );
}

/// Short-lived permission to invoke the ORIGINAL parent's send action.
/// Must be revalidated after every async gap (pairing, file picker, etc.).
@immutable
class MiniChatSessionTicket {
  const MiniChatSessionTicket._({
    required this.peerId,
    required this.authenticatedFingerprint,
    required this.generation,
  });

  final String peerId;
  final String authenticatedFingerprint;
  final int generation;
}

/// An in-process VIEW coordinator, not a secondary chat/transport engine.
///
/// E21-B can reuse it when constructing the visible Windows mini panel.
/// Closing/minimizing the panel never tears down the parent's connection.
class WindowsMiniChatSessionCoordinator extends ChangeNotifier {
  MiniChatViewPhase _phase = MiniChatViewPhase.closed;
  MiniChatOwnerSnapshot _owner = MiniChatOwnerSnapshot.disconnected;
  int _generation = 0;
  bool _disposed = false;

  MiniChatViewPhase get phase => _phase;
  MiniChatOwnerSnapshot get owner => _owner;
  int get generation => _generation;
  bool get visible => _phase == MiniChatViewPhase.visible;
  bool get canSendText => visible && _owner.canSendText;
  bool get canAddFile => visible && _owner.canAddFile;

  /// E21-A deliberately prevents a mini view on Android. This method changes
  /// only presentation state: never calls a network or file operation.
  bool open({required bool isWindows}) {
    if (!isWindows || _disposed) return false;
    if (_phase != MiniChatViewPhase.visible) {
      _phase = MiniChatViewPhase.visible;
      notifyListeners();
    }
    return true;
  }

  void minimize() {
    if (_disposed || _phase != MiniChatViewPhase.visible) return;
    _phase = MiniChatViewPhase.minimized;
    _generation++; // hide invalidates callbacks pending from the mini UI
    notifyListeners();
  }

  bool restore({required bool isWindows}) {
    if (!isWindows || _disposed || _phase != MiniChatViewPhase.minimized) {
      return false;
    }
    _phase = MiniChatViewPhase.visible;
    notifyListeners();
    return true;
  }

  void close() {
    if (_disposed || _phase == MiniChatViewPhase.closed) return;
    _phase = MiniChatViewPhase.closed;
    _generation++; // no stale callbacks may send from a closed window
    notifyListeners();
  }

  /// The trusted owner pushes its CURRENT state; no guessing from peer names.
  /// Invalidate outstanding action tickets if the recipient, channel readiness
  /// or vault identity check changes. A busy/progress repaint does not need to
  /// invalidate the identity generation.
  void publishOwnerSnapshot(MiniChatOwnerSnapshot next) {
    if (_disposed) return;
    final previous = _owner;
    final identityBoundaryChanged =
        previous.peerId != next.peerId ||
        previous.authenticatedFingerprint != next.authenticatedFingerprint ||
        previous.encryptedChannelReady != next.encryptedChannelReady ||
        previous.identityEnrolled != next.identityEnrolled ||
        previous.peerDiscovered != next.peerDiscovered ||
        previous.textHistoryAvailable != next.textHistoryAvailable;
    _owner = next;
    if (identityBoundaryChanged) _generation++;
    notifyListeners();
  }

  MiniChatSessionTicket? issueTextTicket() {
    if (!canSendText) return null;
    return MiniChatSessionTicket._(
      peerId: _owner.peerId!,
      authenticatedFingerprint: _owner.authenticatedFingerprint!,
      generation: _generation,
    );
  }

  MiniChatSessionTicket? issueFileTicket() {
    if (!canAddFile) return null;
    return MiniChatSessionTicket._(
      peerId: _owner.peerId!,
      authenticatedFingerprint: _owner.authenticatedFingerprint!,
      generation: _generation,
    );
  }

  bool validateTextTicket(MiniChatSessionTicket? ticket) =>
      _validate(ticket) && canSendText;

  bool validateFileTicket(MiniChatSessionTicket? ticket) =>
      _validate(ticket) && canAddFile;

  bool _validate(MiniChatSessionTicket? ticket) =>
      !_disposed &&
      ticket != null &&
      visible &&
      ticket.generation == _generation &&
      ticket.peerId == _owner.peerId &&
      ticket.authenticatedFingerprint == _owner.authenticatedFingerprint;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
