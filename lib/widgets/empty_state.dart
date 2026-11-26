import 'package:flutter/material.dart';

import '../app/filo_theme.dart';
import 'filo_logo.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    this.useFiloLogo = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;
  final bool useFiloLogo;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(FiloSpacing.page),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (useFiloLogo)
              const FiloLogo(size: 88)
            else
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: Theme.of(context).colorScheme.primary,
                  size: 32,
                ),
              ),
            const SizedBox(height: FiloSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: FiloSpacing.sm),
            Text(description, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: FiloSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    ),
  );
}
