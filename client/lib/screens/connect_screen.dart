/// Initial connection screen.
/// User enters server URL, room ID, role, and username to join a session.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/logger.dart';
import '../models/config.dart';
import '../webrtc/screen_capture.dart';
import 'control_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController(text: 'http://localhost:3000');
  final _userIdController = TextEditingController();
  final _roomIdController = TextEditingController();

  final ScreenCaptureManager _captureProbe = ScreenCaptureManager();
  List<DesktopCapturerSource> _screens = [];
  String? _selectedSourceId;
  bool _loadingScreens = false;

  // Honour `--dart-define=MODE=viewer` so the dedicated viewer window does not
  // default to the controller/sharing role.
  String _selectedRole = () {
    const mode = String.fromEnvironment('MODE', defaultValue: '');
    return mode == 'viewer' ? 'viewer' : 'controller';
  }();

  @override
  void initState() {
    super.initState();
    // Debug convenience: pre-fill the room code with today's date and a random
    // username, so local testing needs zero typing.
    if (kDebugMode) {
      final now = DateTime.now();
      final dateStr = '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      _roomIdController.text = dateStr;
      _userIdController.text = '${100000 + Random().nextInt(900000)}';
    }
    _loadScreens();
  }

  /// Enumerate the available screens (macOS). Results populate the share-screen
  /// picker. If it fails (e.g. permission not yet granted) we simply skip the
  /// picker and let ScreenCaptureManager auto-pick the primary.
  Future<void> _loadScreens() async {
    if (_loadingScreens) return;
    setState(() => _loadingScreens = true);
    try {
      final screens = await _captureProbe.listScreens();
      if (mounted) {
        setState(() {
          _screens = screens;
          if (_selectedSourceId == null && screens.isNotEmpty) {
            _selectedSourceId = screens.first.id;
          }
        });
      }
    } catch (e) {
      log.d('ConnectScreen: listScreens failed: $e');
      if (mounted) setState(() => _screens = []);
    } finally {
      if (mounted) setState(() => _loadingScreens = false);
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _userIdController.dispose();
    _roomIdController.dispose();
    super.dispose();
  }

  /// Picker for the display to share.
  Widget _buildScreenPicker() {
    if (_loadingScreens) {
      return const SizedBox(
        height: 20,
        child: Center(
          child: SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_screens.isEmpty) {
      return const Text('No displays detected — will auto-pick the primary screen',
        style: TextStyle(fontSize: 12, color: Colors.white38));
    }
    return DropdownButtonFormField<String>(
      initialValue: _selectedSourceId,
      decoration: InputDecoration(
        labelText: 'Display to share',
        prefixIcon: const Icon(Icons.desktop_windows_outlined),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      items: _screens
          .map((s) => DropdownMenuItem(value: s.id, child: Text(s.name)))
          .toList(),
      onChanged: (id) => setState(() => _selectedSourceId = id),
    );
  }

  Future<void> _handleConnect() async {
    if (!_formKey.currentState!.validate()) return;

    final config = context.read<AppConfig>();

    // Apply the user-entered server URL so the connection below targets it.
    final serverInput = _serverController.text.trim();
    if (serverInput.isNotEmpty) {
      config.setServerUrl(serverInput);
    }

    final success = await config.login(
      _userIdController.text.trim(),
      _roomIdController.text.trim(),
      _selectedRole,
    );

    if (mounted && success) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ControlScreen(
            userId: _userIdController.text.trim(),
            roomId: _roomIdController.text.trim(),
            role: _selectedRole,
            serverBaseUrl: config.apiUrl,
            token: config.token!,
            screenSourceId: _selectedSourceId,
          ),
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connection failed. Check your details.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote Desktop — Connect'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.computer,
                        size: 48, color: scheme.primary.withValues(alpha: 0.8)),
                    const SizedBox(height: 16),
                    Text(
                      'Remote Desktop',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Enter connection details',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400])),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _serverController,
                      decoration: InputDecoration(
                        labelText: 'Server URL',
                        hintText: 'e.g. http://192.168.1.10:3000',
                        prefixIcon: const Icon(Icons.cloud_outlined),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _userIdController,
                      decoration: InputDecoration(
                        labelText: 'Your Name',
                        hintText: 'e.g. alice',
                        prefixIcon: const Icon(Icons.person_outline),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _roomIdController,
                      decoration: InputDecoration(
                        labelText: 'Room Code',
                        hintText: 'e.g. meeting-01',
                        prefixIcon: const Icon(Icons.meeting_room_outlined),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    const Text('Role',
                      style: TextStyle(fontSize: 12, color: Colors.white70)),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'controller',
                          label: Text('Share Screen'),
                          icon: Icon(Icons.screen_share_outlined),
                        ),
                        ButtonSegment(
                          value: 'viewer',
                          label: Text('Watch & Control'),
                          icon: Icon(Icons.visibility_outlined),
                        ),
                      ],
                      selected: {_selectedRole},
                      showSelectedIcon: false,
                      onSelectionChanged: (Set<String> sel) =>
                          setState(() => _selectedRole = sel.first),
                    ),
                    if (_selectedRole == 'controller') ...[
                      const SizedBox(height: 16),
                      const Text('Share Screen',
                        style: TextStyle(fontSize: 12, color: Colors.white70)),
                      const SizedBox(height: 8),
                      _buildScreenPicker(),
                    ],
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: _handleConnect,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text('Connect',
                        style: Theme.of(context).textTheme.titleLarge),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
