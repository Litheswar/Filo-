import 'package:flutter/material.dart';

import '../app/filo_theme.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(FiloSpacing.page),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: FiloColors.greenPale,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: FiloColors.green, size: 32),
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
