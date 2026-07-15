/// Represents a room that peers can join.
class Room {
  final String id;
  final String role; // 'controller' or 'viewer'
  final String? token;

  const Room({required this.id, required this.role, this.token});

  @override
  String toString() => 'Room(id: $id, role: $role)';
}
