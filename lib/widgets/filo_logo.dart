import 'package:flutter/widgets.dart';

/// The approved Filo brand mark used in compact in-app placements.
class FiloLogo extends StatelessWidget {
  const FiloLogo({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'brand_logo_pic.png',
    width: size,
    height: size,
    fit: BoxFit.contain,
    semanticLabel: 'Filo logo',
  );
}
