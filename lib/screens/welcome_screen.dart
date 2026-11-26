import 'package:flutter/material.dart';

import '../app/filo_theme.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  static const _steps = <_GuideStep>[
    _GuideStep(
      title: 'Import your files',
      body: 'Select documents with Android’s native file picker. Filo can access the files you choose.',
      icon: Icons.file_open_outlined,
    ),
    _GuideStep(
      title: 'Choose a conversion',
      body: 'Open Convert and choose the supported operation that matches the file you want to create.',
      icon: Icons.swap_horiz_rounded,
    ),
    _GuideStep(
      title: 'Local processing',
      body: 'Documents, on your terms. Filo processes managed files locally on this device; conversion does not need an internet connection after installation.',
      icon: Icons.phone_android_rounded,
    ),
    _GuideStep(
      title: 'Find your documents',
      body: 'Converted documents are saved in Library, where you can search, preview, rename, and delete them.',
      icon: Icons.folder_open_outlined,
    ),
    _GuideStep(
      title: 'Export and share',
      body: 'Files stay in Filo until you choose to export or share them. Android and the destination app control what happens after that choice.',
      icon: Icons.ios_share_rounded,
    ),
    _GuideStep(
      title: 'Manage files and privacy',
      body: 'Review Filo-managed storage in Settings and clear temporary files or thumbnail cache there. Local storage is not the same as encryption. Protect your device and its backups using your device settings.',
      icon: Icons.shield_outlined,
    ),
  ];

  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _finish() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Getting started with Filo'),
      leading: IconButton(
        tooltip: 'Back to Filo',
        onPressed: _finish,
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      actions: [
        TextButton(onPressed: _finish, child: const Text('Skip')),
        const SizedBox(width: FiloSpacing.xs),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FiloSpacing.page,
              FiloSpacing.sm,
              FiloSpacing.page,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: (_index + 1) / _steps.length,
                    semanticsLabel: 'Guide progress',
                  ),
                ),
                const SizedBox(width: FiloSpacing.sm),
                Text('${_index + 1} of ${_steps.length}'),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _steps.length,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (context, index) => _GuidePage(step: _steps[index]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: FiloSpacing.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var index = 0; index < _steps.length; index++)
                  Semantics(
                    label: 'Step ${index + 1}',
                    selected: index == _index,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: index == _index ? 22 : 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: index == _index
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FiloSpacing.page,
              FiloSpacing.sm,
              FiloSpacing.page,
              FiloSpacing.md,
            ),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: _index == 0 ? null : () => _goTo(_index - 1),
                  child: const Text('Previous'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _index == _steps.length - 1
                      ? _finish
                      : () => _goTo(_index + 1),
                  child: Text(_index == _steps.length - 1 ? 'Finish' : 'Next'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _GuideStep {
  const _GuideStep({
    required this.title,
    required this.body,
    required this.icon,
  });

  final String title;
  final String body;
  final IconData icon;
}

class _GuidePage extends StatelessWidget {
  const _GuidePage({required this.step});

  final _GuideStep step;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(FiloSpacing.page),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(FiloSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(FiloRadii.control),
                  ),
                  child: Icon(
                    step.icon,
                    color: Theme.of(context).colorScheme.primary,
                    size: 32,
                  ),
                ),
                const SizedBox(height: FiloSpacing.lg),
                Text(step.title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: FiloSpacing.sm),
                Text(step.body, style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
