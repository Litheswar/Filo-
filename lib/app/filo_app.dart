import 'package:flutter/material.dart';

import '../navigation/app_shell.dart';
import '../screens/welcome_screen.dart';
import '../services/storage/theme_preference_store.dart';
import '../widgets/filo_logo.dart';
import 'filo_services.dart';
import 'filo_theme.dart';

typedef FiloServicesInitializer = Future<FiloServices> Function();

class FiloApp extends StatefulWidget {
  const FiloApp({
    super.key,
    this.initializeServices = FiloServices.initialize,
    this.themePreferenceStore,
  });

  final FiloServicesInitializer initializeServices;
  final ThemePreferenceStore? themePreferenceStore;

  @override
  State<FiloApp> createState() => _FiloAppState();
}

class _FiloAppState extends State<FiloApp> {
  late Future<FiloServices> _services;
  late final ThemePreferenceStore _themePreferences;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _themePreferences = widget.themePreferenceStore ?? ThemePreferenceStore();
    _loadThemeMode();
    _services = widget.initializeServices();
  }

  Future<void> _loadThemeMode() async {
    final mode = await _themePreferences.read();
    if (mounted) setState(() => _themeMode = mode);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    await _themePreferences.write(mode);
  }

  void _retryInitialization() {
    final nextServices = widget.initializeServices();
    setState(() {
      _services = nextServices;
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Filo',
    debugShowCheckedModeBanner: false,
    theme: FiloTheme.light,
    darkTheme: FiloTheme.dark,
    themeMode: _themeMode,
    onGenerateRoute: (settings) {
      if (settings.name == '/welcome') {
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const WelcomeScreen(),
        );
      }
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => FutureBuilder<FiloServices>(
          future: _services,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _InitializationScreen();
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return _InitializationErrorScreen(onRetry: _retryInitialization);
            }
            return AppShell(
              services: snapshot.requireData,
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
            );
          },
        ),
      );
    },
  );
}

class _InitializationScreen extends StatelessWidget {
  const _InitializationScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FiloLogo(size: 64),
            SizedBox(height: 20),
            Text('Getting Filo ready…'),
            SizedBox(height: 20),
            SizedBox(width: 180, child: LinearProgressIndicator()),
          ],
        ),
      ),
    ),
  );
}

class _InitializationErrorScreen extends StatelessWidget {
  const _InitializationErrorScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(FiloSpacing.page),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.storage_rounded, size: 48),
                const SizedBox(height: FiloSpacing.md),
                Text(
                  'Filo couldn’t start',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: FiloSpacing.sm),
                const Text(
                  'Your local storage could not be opened. Your existing data has not been replaced.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: FiloSpacing.lg),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
