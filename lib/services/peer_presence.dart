/// LAN presence windows. These are *not* cryptographic device trust.
/// The discovery loop emits UDP hello every 3 seconds; mobile OS scheduling
/// and Wi-Fi power saving can drop several broadcasts consecutively.
const Duration peerFreshWindow = Duration(seconds: 45);
const Duration peerRetainWindow = Duration(seconds: 120);

bool peerRecentlySeen(DateTime lastSeen, DateTime now) =>
    !now.difference(lastSeen).isNegative &&
    now.difference(lastSeen) <= peerFreshWindow;

bool peerExpired(DateTime lastSeen, DateTime now) =>
    now.difference(lastSeen) > peerRetainWindow;
