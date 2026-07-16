/// WebSocket signal client for WebRTC signaling and control commands.
///
/// Uses [RawSocket] + a hand-rolled WebSocket handshake/framing instead of
/// `WebSocket.connect` because, on Flutter macOS, the latter corrupts the URL
/// (ws:// -> http://, appends '#') and 404s. RawSocket sends exact bytes and
/// sidesteps all URL parsing.
///
/// The client auto-reconnects with exponential backoff when the connection
/// drops unexpectedly, and surfaces connection state via [onConnected] /
/// [onDisconnected] / [onReconnected].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/logger.dart';
import 'protocol.dart';

class SignalClient {
  final String serverUrl;
  RawSocket? _rawSocket;
  StreamSubscription<RawSocketEvent>? _subscription;
  final List<Function(SignalMessage)> _listeners = [];
  bool _connected = false;

  // --- Reconnect state ---
  String? _token;
  String? _roomId;
  String? _role;
  bool _intentionalClose = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 6;
  static const Duration _baseReconnectDelay = Duration(seconds: 1);
  Timer? _reconnectTimer;

  /// Connection lifecycle callbacks (driven by the orchestrator).
  Function()? onConnected;
  Function()? onDisconnected;
  Function()? onReconnected;

  SignalClient(this.serverUrl);

  bool get isConnected => _connected;

  // ========== Public API ==========

  /// Open the connection (and keep it open via auto-reconnect).
  Future<void> connect(String token, String roomId, String role) async {
    _token = token;
    _roomId = roomId;
    _role = role;
    _intentionalClose = false;
    await _open();
  }

  /// Close permanently and stop reconnecting.
  void disconnect() {
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _closeSocket();
  }

  // ========== Connection / reconnect ==========

  Future<void> _open() async {
    final uri = Uri.parse(serverUrl);
    if (!uri.hasScheme || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      throw ArgumentError(
          'SignalClient serverUrl must start with ws:// or wss://, got: $serverUrl');
    }
    final host = uri.host;
    final port = uri.port > 0 ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
    final path = uri.path.isEmpty ? '/' : uri.path;

    log.d('SignalClient: connecting to $host:$port$path');
    try {
      _rawSocket = await RawSocket.connect(host, port);
    } catch (e) {
      log.warning('SignalClient: TCP connect failed: $e');
      _scheduleReconnect();
      return;
    }

    final key =
        base64.encode(List<int>.generate(16, (_) => Random().nextInt(256)));
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

    final upgradeCompleter = Completer<void>();
    final httpBuf = StringBuffer();
    var upgraded = false;

    _subscription = _rawSocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final data = _rawSocket?.read();
        if (data == null) return;
        if (!upgraded) {
          httpBuf.write(String.fromCharCodes(data));
          final str = httpBuf.toString();
          if (str.contains('\r\n\r\n')) {
            if (_isUpgradeSuccess(str)) {
              upgraded = true;
              _connected = true;
              _buffer = [];
              final headerEnd = str.indexOf('\r\n\r\n') + 4;
              final remaining = data.sublist(headerEnd > data.length
                  ? data.length
                  : headerEnd - (str.length - data.length));
              if (remaining.isNotEmpty) {
                _buffer.addAll(remaining);
                _processBuffer();
              }
              upgradeCompleter.complete();
            } else {
              _rawSocket?.close();
              upgradeCompleter
                  .completeError(WebSocketException('Upgrade failed:\n$str'));
            }
          }
        } else {
          _buffer.addAll(data);
          _processBuffer();
        }
      } else if (event == RawSocketEvent.closed) {
        _connected = false;
        log.warning('SignalClient: socket closed');
        if (!upgradeCompleter.isCompleted) upgradeCompleter.complete();
        _onSocketClosed();
      }
    });

    try {
      await upgradeCompleter.future;
    } catch (e) {
      log.warning('SignalClient: upgrade failed: $e');
      _onSocketClosed();
      return;
    }

    if (!_connected) return;

    final wasReconnect = _reconnectAttempts > 0;
    _reconnectAttempts = 0;
    await sendJoinRoom(_roomId!, _role!, _token!);
    if (wasReconnect) {
      onReconnected?.call();
    } else {
      onConnected?.call();
    }
  }

  void _onSocketClosed() {
    if (_intentionalClose) return;
    _connected = false;
    onDisconnected?.call();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_intentionalClose) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      log.warning('SignalClient: max reconnect attempts reached');
      return;
    }
    _reconnectAttempts++;
    final delay = _baseReconnectDelay * (1 << (_reconnectAttempts - 1));
    log.info('SignalClient: reconnect #$_reconnectAttempts in ${delay.inSeconds}s');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_intentionalClose) _open();
    });
  }

  void _closeSocket() {
    _connected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _rawSocket?.close();
    _rawSocket = null;
    _buffer = [];
  }

  bool _isUpgradeSuccess(String response) {
    final lines = response.split('\r\n');
    if (lines.isEmpty) return false;
    final statusLine = lines[0];
    return statusLine.contains('101') &&
        statusLine.contains('Switching Protocols');
  }

  // ========== Frame handling ==========

  List<int> _buffer = [];

  void _processBuffer() {
    while (_buffer.length >= 2) {
      final byte0 = _buffer[0];
      final byte1 = _buffer[1];
      final masked = (byte1 & 0x80) != 0;
      var lenField = byte1 & 0x7F;
      var headerLen = 2;
      var payloadLen = lenField;

      if (lenField == 126) {
        headerLen += 2;
        if (_buffer.length < headerLen) break;
        payloadLen = (_buffer[2] << 8) | _buffer[3];
      } else if (lenField == 127) {
        headerLen += 8;
        if (_buffer.length < headerLen) break;
        payloadLen = 0;
        for (var i = 0; i < 8; i++) {
          payloadLen = (payloadLen << 8) | _buffer[2 + i];
        }
      }

      var maskKeyStart = headerLen;
      if (masked) headerLen += 4;

      final totalLen = headerLen + payloadLen;
      if (_buffer.length < totalLen) break;

      final maskKey =
          masked ? _buffer.sublist(maskKeyStart, maskKeyStart + 4) : null;
      final payloadBytes = _buffer.sublist(headerLen, totalLen);
      final decoded =
          masked ? _unmask(payloadBytes, maskKey!) : payloadBytes;
      _buffer = _buffer.sublist(totalLen);

      final opCode = byte0 & 0x0F;
      if (opCode == 0x1 || opCode == 0x9 || opCode == 0xA) {
        if (opCode == 0x9) {
          _sendFrame(0xA, decoded); // pong
        } else if (opCode == 0x1) {
          try {
            final msg = SignalMessage.fromJson(
                jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>);
            log.d('SignalClient: ↓ ${msg.type}'
                '${msg.from != null ? ' from=${msg.from}' : ''}'
                '${msg.to != null ? ' to=${msg.to}' : ''}');
            _handleMessage(msg);
          } catch (e) {
            log.warning('SignalClient: failed to parse message: $e');
          }
        }
      } else if (opCode == 0x8) {
        log.d('SignalClient: received close frame');
        disconnect();
      }
    }
  }

  List<int> _unmask(List<int> data, List<int> maskKey) {
    final result = List<int>.filled(data.length, 0);
    for (var i = 0; i < data.length; i++) {
      result[i] = data[i] ^ maskKey[i % 4];
    }
    return result;
  }

  void _sendFrame(int opCode, List<int> payload) {
    if (_rawSocket == null) return;
    final payloadLen = payload.length;
    List<int> header;

    if (payloadLen < 126) {
      header = [0x80 | opCode, 0x80 | payloadLen];
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
        0,
        0,
        0,
        0, // high 32 bits of the 64-bit length (0 for our payloads)
        (payloadLen >> 24) & 0xFF,
        (payloadLen >> 16) & 0xFF,
        (payloadLen >> 8) & 0xFF,
        payloadLen & 0xFF,
      ];
    }

    final maskKey = List<int>.generate(4, (_) => Random().nextInt(256));
    header.addAll(maskKey);

    final masked = List<int>.filled(payloadLen, 0);
    for (var i = 0; i < payloadLen; i++) {
      masked[i] = payload[i] ^ maskKey[i % 4];
    }

    final frame = [...header, ...masked];
    _rawSocket!.write(frame, 0, frame.length);
  }

  // ========== Outbound messages ==========

  Future<void> sendJoinRoom(String roomId, String role, String token) async {
    await _send(SignalMessage(
      type: SignalType.joinRoom,
      payload: {'roomId': roomId, 'role': role, 'token': token},
    ));
  }

  Future<void> sendOffer(dynamic sdp, String roomId, [String? to]) async {
    await _send(SignalMessage(
      type: SignalType.offer,
      payload: {'sdp': sdp.toMap()},
      roomId: roomId,
      to: to,
    ));
  }

  Future<void> sendAnswer(dynamic sdp, String roomId, [String? to]) async {
    await _send(SignalMessage(
      type: SignalType.answer,
      payload: {'sdp': sdp.toMap()},
      roomId: roomId,
      to: to,
    ));
  }

  Future<void> sendIceCandidate(
      RTCIceCandidate candidate, String roomId, String? to) async {
    await _send(SignalMessage(
      type: SignalType.iceCandidate,
      payload: candidate.toMap(),
      roomId: roomId,
      to: to,
    ));
  }

  Future<void> sendMouseEvent(
      String action, double x, double y, int button, String roomId) async {
    await _send(SignalMessage(
      type: SignalType.mouseEvent,
      payload: {'action': action, 'x': x, 'y': y, 'button': button},
      roomId: roomId,
    ));
  }

  Future<void> sendKeyEvent(
      String key, String code, String action, String roomId) async {
    await _send(SignalMessage(
      type: SignalType.keyEvent,
      payload: {'key': key, 'code': code, 'action': action},
      roomId: roomId,
    ));
  }

  Future<void> sendKeyEventWithCode(
      String action, int keyCode, String roomId) async {
    await _send(SignalMessage(
      type: SignalType.keyEvent,
      payload: {'action': action, 'keyCode': keyCode},
      roomId: roomId,
    ));
  }

  Future<void> leaveRoom() async {
    await _send(SignalMessage(type: SignalType.leaveRoom));
  }

  // ========== Listeners ==========

  void addListener(Function(SignalMessage) listener) {
    _listeners.add(listener);
  }

  void removeListener(Function(SignalMessage) listener) {
    _listeners.remove(listener);
  }

  Future<void> _send(SignalMessage msg) async {
    if (!_connected || _rawSocket == null) {
      log.warning('SignalClient: not connected, cannot send ${msg.type}');
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
