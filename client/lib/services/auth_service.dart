/// Authentication utility for connecting to the signal server.
/// Makes an HTTP POST to the server's /api/auth/join endpoint.
library;

import 'dart:convert';
import 'package:http/http.dart' as http;

import '../core/logger.dart';

class AuthService {
  final String baseUrl;

  AuthService(this.baseUrl);

  /// Get a room-scoped JWT token from the server, or null on failure.
  Future<String?> getToken(String userId, String roomId, String role) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/join'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'roomId': roomId,
          'role': role,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['token'] as String;
      } else {
        log.warning('Auth failed: ${response.statusCode} ${response.body}');
        return null;
      }
    } catch (e) {
      log.warning('Auth error: $e');
      return null;
    }
  }
}
