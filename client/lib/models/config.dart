/// Application-wide configuration and connection state management.
/// Uses the Provider pattern for reactive state updates.
library;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../core/logger.dart';

class AppConfig extends ChangeNotifier {
  static const defaultServerUrl = 'ws://localhost:3000/signal';
  static const defaultApiUrl = 'http://localhost:3000';

  String serverUrl = defaultServerUrl;
  String apiUrl = defaultApiUrl;
  bool _isLoggedIn = false;
  String? _token;
  String? _userId;
  String? _roomId;

  bool get isLoggedIn => _isLoggedIn;
  String? get token => _token;
  String? get userId => _userId;
  String? get roomId => _roomId;

  /// Set the server URL from settings (accepts either a bare host or a full
  /// /signal URL; always normalizes to both the WS and HTTP forms).
  void setServerUrl(String url) {
    if (url.endsWith('/signal')) {
      serverUrl = url;
      apiUrl = url.replaceAll('/signal', '').replaceAll('ws:', 'http:');
    } else {
      serverUrl = '$url/signal';
      apiUrl = url.replaceAll('ws:', 'http:');
    }
    notifyListeners();
  }

  Future<bool> login(String userId, String roomId, String role) async {
    try {
      final response = await http.post(
        Uri.parse('$apiUrl/api/auth/join'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'roomId': roomId,
          'role': role,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _token = data['token'] as String;
        _userId = userId;
        _roomId = roomId;
        _isLoggedIn = true;
        notifyListeners();
        return true;
      } else {
        log.warning('Login failed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      log.warning('Login error: $e');
      return false;
    }
  }

  void logout() {
    _token = null;
    _userId = null;
    _roomId = null;
    _isLoggedIn = false;
    notifyListeners();
  }
}
