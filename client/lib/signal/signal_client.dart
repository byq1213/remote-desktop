/// WebSocket signal client for WebRTC signaling and control commands.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Message types for the signal protocol.
abstract class SignalType {
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
///
/// Uses [RawSocket] + manual WebSocket handshake/framing instead of
/// [WebSocket.connect] because on Flutter macOS, WebSocket.connect corrupts
/// the URL (ws:// -> http://, appends '#'), causing HTTP 404.
/// RawSocket sends exact bytes and avoids all URL parsing bugs.
class SignalClient {
  final String serverUrl;
  RawSocket? _rawSocket;
  StreamSubscription<RawSocketEvent>? _subscription;
  final List<Function(SignalMessage)> _listeners = [];
  int _requestId = 0;
  bool _connected = false;

  /// Accumulated incomplete data from raw socket reads.
  List<int> _buffer = [];

  SignalClient(this.serverUrl);

  bool get isConnected => _connected;

  /// Connect to signal server with JWT token.
  Future<void> connect(String token, String roomId, String role) async {
    final uri = Uri.parse(serverUrl);
    if (!uri.hasScheme || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      throw ArgumentError(
          'SignalClient serverUrl must start with ws:// or wss://, got: $serverUrl');
    }

    final host = uri.host;
    final port = uri.port > 0 ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
    final path = uri.path.isEmpty ? '/' : uri.path;

    print('SignalClient: connecting to $host:$port$path');

    // 1. TCP connect
    _rawSocket = await RawSocket.connect(host, port);

    // 2. Send HTTP upgrade request manually (exact bytes, no URL parsing)
    final key = base64.encode(List<int>.generate(16, (_) => Random().nextInt(256)));
    final requestStr = [
      'GET $path HTTP/1.1\r\n',
      'Host: $host\r\n',
      'Upgrade: websocket\r\n',
      'Connection: Upgrade\r\n',
      'Sec-WebSocket-Key: $key\r\n',
      'Sec-WebSocket-Version: 13\r\n',
      'Sec-WebSocket-Protocol: signal\r\n',
      '\r\n',
    ].join();
    final requestBytes = utf8.encode(requestStr);
    _rawSocket!.write(requestBytes, 0, requestBytes.length);

    // 3. Read 101 Switching Protocols response using single listener,
    //    then seamlessly transition to WebSocket frame processing
    final upgradeCompleter = Completer<void>();
    StringBuffer httpBuf = StringBuffer();
    bool upgraded = false;

    _subscription = _rawSocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        var data = _rawSocket?.read();
        if (data == null) return;

        if (!upgraded) {
          // Phase 1: collecting HTTP response headers
          httpBuf.write(String.fromCharCodes(data));
          final str = httpBuf.toString();
          if (str.contains('\r\n\r\n')) {
            print('SignalClient: upgrade response:\n$str');
            if (_isUpgradeSuccess(str)) {
              upgraded = true;
              _connected = true;
              _buffer = [];
              print('SignalClient: upgraded to WebSocket');
              // Any remaining bytes after \r\n\r\n are WebSocket frame data
              final headerEnd = str.indexOf('\r\n\r\n') + 4;
              final remainingBytes = data.sublist(
                headerEnd > data.length ? data.length : headerEnd - (str.length - data.length),
              );
              if (remainingBytes.isNotEmpty) {
                _buffer.addAll(remainingBytes);
                _processBuffer();
              }
              if (!upgradeCompleter.isCompleted) upgradeCompleter.complete();
            } else {
              _rawSocket?.close();
              if (!upgradeCompleter.isCompleted) {
                upgradeCompleter.completeError(
                  WebSocketException('WebSocket upgrade failed:\n$str'));
              }
            }
          }
        } else {
          // Phase 2: WebSocket frame data
          _buffer.addAll(data);
          _processBuffer();
        }
      } else if (event == RawSocketEvent.closed) {
        _connected = false;
        print('SignalClient: socket closed');
        if (!upgradeCompleter.isCompleted) upgradeCompleter.complete();
      }
    });

    await upgradeCompleter.future;
    print('SignalClient: connected to $serverUrl');

    // Join room
    await sendJoinRoom(roomId, role, token);
  }

  /// Check if the HTTP response is a successful WebSocket upgrade.
  bool _isUpgradeSuccess(String response) {
    final lines = response.split('\r\n');
    if (lines.isEmpty) return false;
    final statusLine = lines[0];
    return statusLine.contains('101') &&
        statusLine.contains('Switching Protocols');
  }

  /// Process accumulated buffer, extracting complete WebSocket frames.
  void _processBuffer() {
    while (_buffer.length >= 2) {
      // Minimum frame: 2 bytes header
      final byte0 = _buffer[0];
      final byte1 = _buffer[1];
      final masked = (byte1 & 0x80) != 0;
      final lenField = byte1 & 0x7F;
      var headerLen = 2;
      var payloadLen = lenField;

      if (lenField == 126) {
        headerLen += 2; // 16-bit length follows
        if (_buffer.length < headerLen) break;
        payloadLen = (_buffer[2] << 8) | _buffer[3];
      } else if (lenField == 127) {
        headerLen += 8; // 64-bit length follows
        if (_buffer.length < headerLen) break;
        payloadLen = 0;
        for (var i = 0; i < 8; i++) {
          payloadLen = (payloadLen << 8) | _buffer[2 + i];
        }
      }

      var maskKeyStart = headerLen;
      if (masked) headerLen += 4; // masking key

      final totalLen = headerLen + payloadLen;
      if (_buffer.length < totalLen) break; // not enough data yet

      // Extract payload
      final maskKey = masked
          ? _buffer.sublist(maskKeyStart, maskKeyStart + 4)
          : null;
      final payloadBytes = _buffer.sublist(headerLen, totalLen);

      // Unmask if needed
      final decoded = masked ? _unmask(payloadBytes, maskKey!) : payloadBytes;

      // Remove consumed bytes from buffer
      _buffer = _buffer.sublist(totalLen);

      // Handle the frame
      final opCode = byte0 & 0x0F;
      if (opCode == 0x1 || opCode == 0x9 || opCode == 0xA) {
        // Text frame (0x1), Ping (0x9), Pong (0xA)
        if (opCode == 0x9) {
          // Respond to ping with pong
          _sendFrame(0xA, decoded);
        } else if (opCode == 0x1) {
          // Text frame - decode and dispatch
          final msgStr = utf8.decode(decoded);
          try {
            final msg = SignalMessage.fromJson(
                jsonDecode(msgStr) as Map<String, dynamic>);
            print('SignalClient: ↓ ${msg.type}'
                '${msg.from != null ? ' from=${msg.from}' : ''}'
                '${msg.to != null ? ' to=${msg.to}' : ''}');
            _handleMessage(msg);
          } catch (e) {
            print('SignalClient: failed to parse message: $e');
          }
        }
      } else if (opCode == 0x8) {
        // Close frame
        print('SignalClient: received close frame');
        close();
      }
    }
  }

  /// XOR-unmask WebSocket payload.
  List<int> _unmask(List<int> data, List<int> maskKey) {
    final result = List<int>.filled(data.length, 0);
    for (var i = 0; i < data.length; i++) {
      result[i] = data[i] ^ maskKey[i % 4];
    }
    return result;
  }

  /// Send a WebSocket frame with given opcode and payload.
  void _sendFrame(int opCode, List<int> payload) {
    if (_rawSocket == null) return;
    final payloadLen = payload.length;
    List<int> header;

    if (payloadLen < 126) {
      header = [
        0x80 | opCode, // FIN=1, opcode
        0x80 | payloadLen, // MASK=1, length (client must mask)
      ];
    } else if (payloadLen < 65536) {
      header = [
        0x80 | opCode,
        0x80 | 126,
        (payloadLen >> 8) & 0xFF,
        payloadLen & 0xFF,
      ];
    } else {
      header = [
        0x80 | opCode,
        0x80 | 127,
        0, 0, 0, 0,
        (payloadLen >> 24) & 0xFF,
        (payloadLen >> 16) & 0xFF,
        (payloadLen >> 8) & 0xFF,
        payloadLen & 0xFF,
      ];
    }

    // Generate random mask key
    final maskKey = List<int>.generate(4, (_) => Random().nextInt(256));
    header.addAll(maskKey);

    // Mask the payload
    final masked = List<int>.filled(payloadLen, 0);
    for (var i = 0; i < payloadLen; i++) {
      masked[i] = payload[i] ^ maskKey[i % 4];
    }

    final frame = [...header, ...masked];
    _rawSocket!.write(frame, 0, frame.length);
  }

  /// Send JOIN_ROOM message with JWT token for authentication.
  Future<void> sendJoinRoom(String roomId, String role, String token) async {
    await _send(SignalMessage(
      type: SignalType.joinRoom,
      payload: {'roomId': roomId, 'role': role, 'token': token},
    ));
  }

  /// Send WebRTC offer.
  Future<void> sendOffer(dynamic sdp, String roomId, [String? to]) async {
    await _send(SignalMessage(
      type: SignalType.offer,
      payload: {'sdp': sdp.toMap()},
      roomId: roomId,
      to: to,
    ));
  }

  /// Send WebRTC answer.
  Future<void> sendAnswer(dynamic sdp, String roomId, [String? to]) async {
    await _send(SignalMessage(
      type: SignalType.answer,
      payload: {'sdp': sdp.toMap()},
      roomId: roomId,
      to: to,
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
    _subscription?.cancel();
    _subscription = null;
    _rawSocket?.close();
    _rawSocket = null;
    _listeners.clear();
    _buffer = [];
  }

  // Internal methods
  Future<void> _send(SignalMessage msg) async {
    if (!_connected || _rawSocket == null) {
      print('SignalClient: not connected, cannot send ${msg.type}');
      return;
    }
    final jsonStr = jsonEncode(msg.toJson());
    _sendFrame(0x1, utf8.encode(jsonStr));
  }

  void _handleMessage(SignalMessage msg) {
    for (final listener in List.from(_listeners)) {
      listener(msg);
    }
  }
}
