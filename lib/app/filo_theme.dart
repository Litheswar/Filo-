import 'package:flutter/material.dart';

abstract final class FiloColors {
  static const ink = Color(0xFF202A26);
  static const mutedInk = Color(0xFF66716C);
  static const green = Color(0xFF286B55);
  static const greenDark = Color(0xFF174B3A);
  static const greenPale = Color(0xFFE8F2ED);
  static const canvas = Color(0xFFF7F8F5);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE3E8E3);
  static const warning = Color(0xFF8C4B13);
}

abstract final class FiloSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double page = 24;
}

abstract final class FiloRadii {
  static const double card = 20;
  static const double control = 14;
  static const double pill = 100;
}

abstract final class FiloTheme {
  static ThemeData get light {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: FiloColors.green,
          brightness: Brightness.light,
          surface: FiloColors.surface,
        ).copyWith(
          primary: FiloColors.green,
          onPrimary: Colors.white,
          secondary: FiloColors.greenDark,
          surface: FiloColors.surface,
          onSurface: FiloColors.ink,
          outline: FiloColors.border,
        );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: FiloColors.canvas,
      textTheme: base.textTheme
          .apply(bodyColor: FiloColors.ink, displayColor: FiloColors.ink)
          .copyWith(
            headlineLarge: base.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.7,
            ),
            headlineMedium: base.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            bodyMedium: base.textTheme.bodyMedium?.copyWith(
              color: FiloColors.mutedInk,
              height: 1.45,
            ),
          ),
      cardTheme: CardThemeData(
        color: FiloColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FiloRadii.card),
          side: const BorderSide(color: FiloColors.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FiloRadii.control),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 50),
          side: const BorderSide(color: FiloColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FiloRadii.control),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: FiloColors.surface,
        contentPadding: const EdgeInsets.all(FiloSpacing.md),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(FiloRadii.control),
          borderSide: const BorderSide(color: FiloColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(FiloRadii.control),
          borderSide: const BorderSide(color: FiloColors.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: FiloColors.surface,
        indicatorColor: FiloColors.greenPale,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? FiloColors.greenDark : FiloColors.mutedInk,
          );
        }),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: FiloColors.canvas,
        foregroundColor: FiloColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      dividerColor: FiloColors.border,
    );
  }
}
