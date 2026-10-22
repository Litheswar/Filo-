import 'package:flutter/material.dart';

import '../navigation/app_shell.dart';
import '../screens/welcome_screen.dart';
import 'filo_services.dart';
import 'filo_theme.dart';

typedef FiloServicesInitializer = Future<FiloServices> Function();

class FiloApp extends StatefulWidget {
  const FiloApp({super.key, this.initializeServices = FiloServices.initialize});

  final FiloServicesInitializer initializeServices;

  @override
  State<FiloApp> createState() => _FiloAppState();
}

class _FiloAppState extends State<FiloApp> {
  late Future<FiloServices> _services;

  @override
  void initState() {
    super.initState();
    _services = widget.initializeServices();
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
            return AppShell(services: snapshot.requireData);
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
            _FiloMark(size: 64),
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

class _FiloMark extends StatelessWidget {
  const _FiloMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: FiloColors.greenPale,
      borderRadius: BorderRadius.circular(size * 0.32),
    ),
    child: Icon(
      Icons.description_rounded,
      color: FiloColors.green,
      size: size * 0.52,
    ),
  );
}
