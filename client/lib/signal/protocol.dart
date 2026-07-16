/// Shared signaling protocol constants and message model.
///
/// Keeping the message types in one place avoids the client/server string
/// drift that raw `'JOIN_ROOM'` literals invite (the server switches on the
/// same string values).
library;

/// Wire message types. Values match what the signal server switches on.
class SignalType {
  static const String joinRoom = 'JOIN_ROOM';
  static const String roomJoined = 'ROOM_JOINED';
  static const String peerJoined = 'PEER_JOINED';
  static const String offer = 'OFFER';
  static const String answer = 'ANSWER';
  static const String iceCandidate = 'ICE_CANDIDATE';
  static const String mouseEvent = 'MOUSE_EVENT';
  static const String keyEvent = 'KEY_EVENT';
  static const String leaveRoom = 'LEAVE_ROOM';
  static const String peerLeft = 'PEER_LEFT';
  static const String authError = 'AUTH_ERROR';
}

/// A signaling message exchanged over the WebSocket.
class SignalMessage {
  final String type;
  final dynamic payload;
  final String? roomId;
  final String? from;
  final String? to;

  SignalMessage({
    required this.type,
    this.payload,
    this.roomId,
    this.from,
    this.to,
  });

  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    return SignalMessage(
      type: json['type'] as String,
      payload: json['payload'],
      roomId: json['roomId'] as String?,
      from: json['from'] as String?,
      to: json['to'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      if (payload != null) 'payload': payload,
      if (roomId != null) 'roomId': roomId,
      if (from != null) 'from': from,
      if (to != null) 'to': to,
    };
  }

  @override
  String toString() => 'SignalMessage(type: $type, roomId: $roomId)';
}
