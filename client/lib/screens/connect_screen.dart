/// Initial connection screen.
/// User enters server URL, room ID, role, and username to join a session.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/config.dart';
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

  // Honour `--dart-define=MODE=viewer` (see README) so the dedicated
  // viewer window does not default to the controller/sharing role.
  String _selectedRole = () {
    const mode = String.fromEnvironment('MODE', defaultValue: '');
    return mode == 'viewer' ? 'viewer' : 'controller';
  }();

  @override
  void initState() {
    super.initState();
    // Debug convenience: pre-fill the room code with today's date
    // (YYYYMMDD) and a random username, so local testing needs zero typing.
    if (kDebugMode) {
      final now = DateTime.now();
      final dateStr = '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      _roomIdController.text = dateStr;
      _userIdController.text = '${100000 + Random().nextInt(900000)}';
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _userIdController.dispose();
    _roomIdController.dispose();
    super.dispose();
  }

  Future<void> _handleConnect() async {
    if (!_formKey.currentState!.validate()) return;

    final config = context.read<AppConfig>();

    // IMPORTANT: apply the user-entered server URL so the connection below
    // actually targets it (previously this field was ignored).
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
          ),
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connection failed')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
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
                    // Title
                    Icon(Icons.computer, size: 48, color: Colors.deepPurple[200]),
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
                    Text(
                      'Enter connection details',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                    const SizedBox(height: 32),

                    // Server URL
                    TextFormField(
                      controller: _serverController,
                      decoration: InputDecoration(
                        labelText: 'Server URL',
                        hintText: 'e.g. http://192.168.1.10:3000',
                        helperText: 'Default points to a local server. Change it to reach a remote one.',
                        prefixIcon: const Icon(Icons.cloud_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),

                    // User ID
                    TextFormField(
                      controller: _userIdController,
                      decoration: InputDecoration(
                        labelText: 'Your Name',
                        hintText: 'e.g. alice',
                        helperText: 'Example only — type your own name (required).',
                        prefixIcon: const Icon(Icons.person_outline),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),

                    // Room ID
                    TextFormField(
                      controller: _roomIdController,
                      decoration: InputDecoration(
                        labelText: 'Room Code',
                        hintText: 'e.g. meeting-01',
                        helperText: 'Example only — type a shared code (required).',
                        prefixIcon: const Icon(Icons.meeting_room_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),

                    // Role selector — explicit, can't-miss choice.
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
                    const SizedBox(height: 32),

                    // Connect button
                    ElevatedButton(
                      onPressed: _handleConnect,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(
                        'Connect',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
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
