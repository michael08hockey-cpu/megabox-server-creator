import 'package:flutter/material.dart';

class AppTheme {
  // Liquid Glass palette - stepped tonal ladder from near-black
  static const surface1 = Color(0xFF05070C); // deepest (3% lightness)
  static const surface2 = Color(0xFF0A0D12); // 4%
  static const surface3 = Color(0xFF0F131C); // 6%
  static const surface4 = Color(0xFF161D2B); // 9%
  static const surface5 = Color(0xFF1E2636); // 12%

  // Luminous accent - cyan for data/infrastructure domain
  static const accentPrimary = Color(0xFF38BDF8);
  static const accentMuted = Color(0xFF0EA5E9);
  static const accentViolet = Color(0xFFA78BFA);

  /// Фирменный градиент: циан → фиолетовый.
  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF38BDF8), Color(0xFF818CF8), Color(0xFFA78BFA)],
  );

  /// Карточка «стекло»: полупрозрачный фон, тонкая светлая рамка.
  static BoxDecoration glassCard({double radius = radiusLarge, Color? glow}) =>
      BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            surface3.withValues(alpha: 0.95),
            surface2.withValues(alpha: 0.95),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: (glow ?? Colors.black).withValues(alpha: glow == null ? 0.35 : 0.18),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      );

  // Semantic colors
  static const success = Color(0xFF6EE7B7);
  static const warning = Color(0xFFFBBF24);
  static const error = Color(0xFFF87171);
  static const textPrimary = Color(0xFFE5E7EB);
  static const textSecondary = Color(0xFF9CA3AF);
  static const textMuted = Color(0xFF6B7280);

  // Spacing scale
  static const spacing4 = 4.0;
  static const spacing8 = 8.0;
  static const spacing12 = 12.0;
  static const spacing16 = 16.0;
  static const spacing20 = 20.0;
  static const spacing24 = 24.0;
  static const spacing32 = 32.0;
  static const spacing48 = 48.0;

  // Border radius
  static const radiusSmall = 8.0;
  static const radiusMedium = 12.0;
  static const radiusLarge = 16.0;
  static const radiusPill = 999.0;

  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: surface1,
    colorScheme: const ColorScheme.dark(
      primary: accentPrimary,
      secondary: accentMuted,
      surface: surface2,
      error: error,
    ),
    cardTheme: const CardThemeData(
      color: surface2,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface3,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
        borderSide: const BorderSide(color: accentPrimary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
        borderSide: const BorderSide(color: error, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: spacing16,
        vertical: spacing12,
      ),
      hintStyle: const TextStyle(color: textMuted),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accentPrimary,
        foregroundColor: surface1,
        padding: const EdgeInsets.symmetric(
          horizontal: spacing24,
          vertical: spacing16,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusPill),
        ),
        elevation: 0,
      ),
    ),
    textTheme: const TextTheme(
      displayLarge: TextStyle(
        color: textPrimary,
        fontSize: 32,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
      ),
      displayMedium: TextStyle(
        color: textPrimary,
        fontSize: 24,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.25,
      ),
      bodyLarge: TextStyle(color: textPrimary, fontSize: 16, height: 1.6),
      bodyMedium: TextStyle(color: textSecondary, fontSize: 14, height: 1.5),
      labelLarge: TextStyle(
        color: textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accentPrimary,
        foregroundColor: surface1,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: textPrimary,
        side: const BorderSide(color: surface5),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? surface1 : textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? accentPrimary : surface4,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: surface4,
      contentTextStyle: const TextStyle(color: textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusMedium),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: surface5,
        borderRadius: BorderRadius.circular(radiusSmall),
      ),
      textStyle: const TextStyle(color: textPrimary, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(surface5.withValues(alpha: 0.9)),
      radius: const Radius.circular(8),
    ),
    dividerTheme: const DividerThemeData(
      color: surface4,
      thickness: 1,
      space: 1,
    ),
  );
}
