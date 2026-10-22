import 'package:flutter/material.dart';

import '../app/filo_theme.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('About Filo'),
      leading: IconButton(
        tooltip: 'Back to Filo',
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.arrow_back_rounded),
      ),
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(FiloSpacing.page),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: FiloColors.greenPale,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: const Icon(
                      Icons.description_rounded,
                      color: FiloColors.green,
                      size: 46,
                    ),
                  ),
                ),
                const SizedBox(height: FiloSpacing.xl),
                Text(
                  'Documents, on your terms.',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: FiloSpacing.md),
                const Text(
                  'Filo is designed to convert and manage documents locally on your device.',
                ),
                const SizedBox(height: FiloSpacing.lg),
                const _PromiseRow(
                  icon: Icons.phone_android_rounded,
                  title: 'Kept on this device',
                  body: 'Filo stores managed files in app-managed device storage by default.',
                ),
                const _PromiseRow(
                  icon: Icons.ios_share_rounded,
                  title: 'You choose what leaves',
                  body: 'Files are exported or shared only when you choose to do so.',
                ),
                const _PromiseRow(
                  icon: Icons.person_off_outlined,
                  title: 'No account required',
                  body: 'The local workflow does not require an account.',
                ),
                const SizedBox(height: FiloSpacing.md),
                const Text(
                  'Local storage is not the same as encryption. Protect your device and its backups using your device settings.',
                ),
                const SizedBox(height: FiloSpacing.xl),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      } else {
                        Navigator.of(context).pushReplacementNamed('/');
                      }
                    },
                    child: const Text('Continue to Filo'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _PromiseRow extends StatelessWidget {
  const _PromiseRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FiloSpacing.md),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: FiloColors.green),
        const SizedBox(width: FiloSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: FiloSpacing.xs),
              Text(body),
            ],
          ),
        ),
      ],
    ),
  );
}
