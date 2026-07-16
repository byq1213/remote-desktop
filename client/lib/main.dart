/// Main app entry point.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/logger.dart';
import 'models/config.dart';
import 'screens/connect_screen.dart';

void main() {
  setupLogging();
  runApp(const RemoteDesktopApp());
}

class RemoteDesktopApp extends StatelessWidget {
  const RemoteDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppConfig()),
      ],
      child: MaterialApp(
        title: 'Remote Desktop',
        debugShowCheckedModeBanner: false,
        theme: _darkTheme,
        darkTheme: _darkTheme,
        themeMode: ThemeMode.dark,
        home: const ConnectScreen(),
      ),
    );
  }

  static final _darkTheme = ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.dark(
      primary: Colors.deepPurple,
      secondary: Colors.blueAccent,
      surface: Colors.grey[900]!,
      onSurface: Colors.white,
    ),
    useMaterial3: true,
    fontFamily: 'Roboto',
  );
}
