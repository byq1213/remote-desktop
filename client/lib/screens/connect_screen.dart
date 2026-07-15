/// Initial connection screen.
/// User enters server URL, room ID, role, and username to join a session.
library;

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
  String _selectedRole = 'controller';

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
                      hintText: 'http://localhost:3000',
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
                        hintText: 'viewer-1',
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
                        hintText: 'abc123',
                        prefixIcon: const Icon(Icons.meeting_room_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),

                    // Role selector
                    DropdownButtonFormField<String>(
                      value: _selectedRole,
                      decoration: InputDecoration(
                        labelText: 'Role',
                        prefixIcon: const Icon(Icons.admin_panel_settings_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'controller', child: Text('Controller (Share Screen)')),
                        DropdownMenuItem(value: 'viewer', child: Text('Viewer (Watch & Control)')),
                      ],
                      onChanged: (v) => setState(() => _selectedRole = v!),
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
