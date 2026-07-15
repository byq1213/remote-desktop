/// WebSocket signal client for WebRTC signaling and control commands.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

/// Message types for the signal protocol.
abstract class SignalType {
  static const String joinRoom = 'JOIN_ROOM';
  static const String roomJoined = 'ROOM_JOINED';
  static const String offer = 'OFFER';
  static const String answer = 'ANSWER';
  static const String iceCandidate = 'ICE_CANDIDATE';
  static const String mouseEvent = 'MOUSE_EVENT';
  static const String keyEvent = 'KEY_EVENT';
  static const String leaveRoom = 'LEAVE_ROOM';
  static const String peerLeft = 'PEER_LEFT';
  static const String authError = 'AUTH_ERROR';
}

/// Signal message schema.
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

/// WebSocket signal client that manages the connection to the signal server.
class SignalClient {
  final String serverUrl;
  WebSocketChannel? _channel;
  final List<Function(SignalMessage)> _listeners = [];
  final Map<String, Completer<SignalMessage?>> _pendingRequests = {};
  int _requestId = 0;
  bool _connected = false;

  SignalClient(this.serverUrl);

  bool get isConnected => _connected;

  /// Connect to signal server with JWT token.
  Future<void> connect(String token, String roomId, String role) async {
    _channel = IOWebSocketChannel.connect(
      serverUrl,
      headers: {'Authorization': 'Bearer $token'},
      pingInterval: Duration(seconds: 30),
    );
    _connected = true;

    // Listen for incoming messages
    _channel!.stream.listen(
      (data) {
        final msg = SignalMessage.fromJson(jsonDecode(data) as Map<String, dynamic>);
        _handleMessage(msg);
      },
      onError: (error) {
        _connected = false;
        print('SignalClient error: $error');
      },
      onDone: () {
        _connected = false;
        print('SignalClient disconnected');
      },
    );

    // Join room — pass token so server can verify JWT
    await sendJoinRoom(roomId, role, token);
  }

  /// Send JOIN_ROOM message with JWT token for authentication.
  Future<void> sendJoinRoom(String roomId, String role, String token) async {
    await _send(SignalMessage(
      type: SignalType.joinRoom,
      payload: {'roomId': roomId, 'role': role, 'token': token},
    ));
  }

  /// Send WebRTC offer.
  Future<void> sendOffer(dynamic sdp, String roomId) async {
    await _send(SignalMessage(
      type: SignalType.offer,
      payload: {'sdp': sdp.toMap()},
      roomId: roomId,
    ));
  }

  /// Send WebRTC answer.
  Future<void> sendAnswer(dynamic sdp, String roomId) async {
    await _send(SignalMessage(
      type: SignalType.answer,
      payload: {'sdp': sdp.toMap()},
      roomId: roomId,
    ));
  }

  /// Send ICE candidate.
  Future<void> sendIceCandidate(
      RTCIceCandidate candidate, String roomId, String? to) async {
    final candidateJson = candidate.toMap();
    await _send(SignalMessage(
      type: SignalType.iceCandidate,
      payload: candidateJson,
      roomId: roomId,
      to: to,
    ));
  }

  /// Send mouse event.
  Future<void> sendMouseEvent(
      String action, double x, double y, int button, String roomId) async {
    await _send(SignalMessage(
      type: SignalType.mouseEvent,
      payload: {
        'action': action,
        'x': x,
        'y': y,
        'button': button,
      },
      roomId: roomId,
    ));
  }

  /// Send key event.
  Future<void> sendKeyEvent(
      String key, String code, String action, String roomId) async {
    await _send(SignalMessage(
      type: SignalType.keyEvent,
      payload: {'key': key, 'code': code, 'action': action},
      roomId: roomId,
    ));
  }

  /// Leave room.
  Future<void> leaveRoom() async {
    await _send(SignalMessage(type: SignalType.leaveRoom));
  }

  /// Register listener for signal messages.
  void addListener(Function(SignalMessage) listener) {
    _listeners.add(listener);
  }

  /// Remove listener.
  void removeListener(Function(SignalMessage) listener) {
    _listeners.remove(listener);
  }

  /// Close connection.
  void close() {
    _connected = false;
    _channel?.sink.close();
    _listeners.clear();
  }

  // Internal methods
  Future<void> _send(SignalMessage msg) async {
    if (!_connected) {
      print('SignalClient: not connected, cannot send ${msg.type}');
      return;
    }
    _channel!.sink.add(jsonEncode(msg.toJson()));
  }

  void _handleMessage(SignalMessage msg) {
    for (final listener in List.from(_listeners)) {
      listener(msg);
    }
  }
}
