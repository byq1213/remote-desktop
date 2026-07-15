/// Represents a peer (controller or viewer) in a room.
class PeerInfo {
  final String userId;
  final String role;

  const PeerInfo({required this.userId, required this.role});

  @override
  String toString() => 'PeerInfo(userId: $userId, role: $role)';
}
