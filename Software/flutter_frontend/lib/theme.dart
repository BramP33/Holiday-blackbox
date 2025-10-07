import 'package:flutter/material.dart';

class AppColors {
  static const Color forest = Color(0xFF144834); // deep green with 6-bit friendly channel values
  static const Color charcoal = Color(0xFF101418);
  static const Color charcoalAlt = Color(0xFF161C20);
  static const Color charcoalSoft = Color(0xFF1E262A);
  static const Color kraft = Color(0xFFF0E0C0);
  static const Color amber = Color(0xFFF0A800);
  static const Color rust = Color(0xFFB44C24);
  static const Color sage = Color(0xFF688870);
  static const Color parchmentOverlay = Color(0xCCF0E0C0);
  static const Color topoLine = Color(0x26F0E0C0);
  static const Color sky = Color(0xFF4A90C0);

  const AppColors._();
}

class AppFonts {
  static const String inter = 'Inter';
  static const String oswald = 'Oswald';
  static const String spectralSc = 'SpectralSC';

  const AppFonts._();
}

TextStyle _interStyle({
  Color? color,
  double? size,
  FontWeight weight = FontWeight.w400,
  double? letterSpacing,
  FontStyle fontStyle = FontStyle.normal,
}) {
  return TextStyle(
    fontFamily: AppFonts.inter,
    fontWeight: weight,
    color: color,
    fontSize: size,
    letterSpacing: letterSpacing,
    fontStyle: fontStyle,
  );
}

TextStyle _oswaldStyle({
  Color? color,
  double? size,
  FontWeight weight = FontWeight.w400,
  double? letterSpacing,
}) {
  return TextStyle(
    fontFamily: AppFonts.oswald,
    fontWeight: weight,
    color: color,
    fontSize: size,
    letterSpacing: letterSpacing,
  );
}

TextStyle _spectralStyle({
  Color? color,
  double? size,
  FontWeight weight = FontWeight.w400,
  double? letterSpacing,
}) {
  return TextStyle(
    fontFamily: AppFonts.spectralSc,
    fontWeight: weight,
    color: color,
    fontSize: size,
    letterSpacing: letterSpacing,
  );
}

class AppTheme {
  const AppTheme._();

  static ThemeData build() {
    final colorScheme = ColorScheme.dark(
      primary: AppColors.amber,
      onPrimary: AppColors.charcoal,
      primaryContainer: AppColors.forest,
      onPrimaryContainer: AppColors.kraft,
      secondary: AppColors.rust,
      onSecondary: AppColors.kraft,
      secondaryContainer: AppColors.charcoalSoft,
      onSecondaryContainer: AppColors.kraft,
      tertiary: AppColors.sky,
      onTertiary: AppColors.charcoal,
      surface: AppColors.charcoalSoft,
      onSurface: AppColors.kraft,
      surfaceVariant: AppColors.charcoalAlt,
      onSurfaceVariant: AppColors.kraft,
      background: AppColors.charcoal,
      onBackground: AppColors.kraft,
      error: const Color(0xFFE05C54),
      onError: AppColors.charcoal,
      outline: AppColors.sage,
      outlineVariant: const Color(0xFF3C4C42),
      shadow: Colors.black,
      scrim: Colors.black,
    );

    final textTheme = _buildTextTheme(colorScheme);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.charcoal,
      colorScheme: colorScheme,
      textTheme: textTheme,
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.charcoalSoft.withOpacity(0.96),
        behavior: SnackBarBehavior.floating,
        contentTextStyle: _interStyle(
          color: AppColors.kraft,
          size: 16,
          letterSpacing: -0.1,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.sage, width: 1.5),
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
      iconTheme: const IconThemeData(color: AppColors.kraft),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.charcoal,
        foregroundColor: AppColors.kraft,
        elevation: 0,
        titleTextStyle: _oswaldStyle(
          color: AppColors.kraft,
          weight: FontWeight.w600,
          letterSpacing: 1.1,
          size: 20,
        ),
      ),
      cardTheme: CardTheme(
        color: AppColors.charcoalSoft,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: EdgeInsets.zero,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: AppColors.charcoalSoft,
        selectedIconTheme: const IconThemeData(color: AppColors.amber, size: 30),
        selectedLabelTextStyle: _oswaldStyle(
          color: AppColors.amber,
          letterSpacing: 1.0,
          size: 16,
          weight: FontWeight.w600,
        ),
        unselectedIconTheme: const IconThemeData(color: AppColors.sage, size: 26),
        unselectedLabelTextStyle: _oswaldStyle(
          color: AppColors.sage,
          letterSpacing: 1.0,
          size: 14,
          weight: FontWeight.w500,
        ),
        indicatorColor: AppColors.rust,
        useIndicator: true,
        groupAlignment: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.charcoalSoft,
        elevation: 6,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.forest.withOpacity(0.6),
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: MaterialStateProperty.resolveWith<TextStyle?>((states) {
          final base = _oswaldStyle(
            letterSpacing: 1.1,
            size: 14,
            weight: FontWeight.w600,
          );
          if (states.contains(MaterialState.selected)) {
            return base.copyWith(color: AppColors.amber);
          }
          return base.copyWith(color: AppColors.sage);
        }),
        iconTheme: MaterialStateProperty.resolveWith<IconThemeData?>((states) {
          if (states.contains(MaterialState.selected)) {
            return const IconThemeData(color: AppColors.amber, size: 28);
          }
          return const IconThemeData(color: AppColors.sage, size: 26);
        }),
      ),
      tabBarTheme: TabBarTheme(
        indicatorColor: AppColors.amber,
        dividerColor: Colors.transparent,
        labelStyle: _oswaldStyle(
          weight: FontWeight.w600,
          letterSpacing: 1.05,
          size: 15,
          color: AppColors.amber,
        ),
        unselectedLabelStyle: _oswaldStyle(
          weight: FontWeight.w500,
          letterSpacing: 1.0,
          size: 14,
          color: AppColors.sage,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.charcoalSoft,
        border: _journalInputBorder(),
        enabledBorder: _journalInputBorder(),
        focusedBorder: _journalInputBorder(color: AppColors.amber, width: 1.6),
        labelStyle: _interStyle(color: AppColors.sage, size: 14),
        hintStyle: _interStyle(color: AppColors.sage.withOpacity(0.8), size: 14),
        prefixIconColor: AppColors.sage,
        suffixIconColor: AppColors.sage,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.sage,
        thickness: 1.0,
        space: 24,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: MaterialStateProperty.resolveWith<Color?>((states) {
            if (states.contains(MaterialState.disabled)) {
              return AppColors.sage.withOpacity(0.2);
            }
            return AppColors.forest;
          }),
          foregroundColor: MaterialStateProperty.all<Color>(AppColors.kraft),
          overlayColor: MaterialStateProperty.all<Color>(AppColors.amber.withOpacity(0.2)),
          shape: MaterialStateProperty.all<RoundedRectangleBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AppColors.rust, width: 2),
            ),
          ),
          padding: MaterialStateProperty.all<EdgeInsets>(
            const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          textStyle: MaterialStateProperty.all<TextStyle>(
            _oswaldStyle(
              weight: FontWeight.w600,
              letterSpacing: 1.0,
              size: 16,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: MaterialStateProperty.all<Color>(AppColors.charcoalSoft),
          foregroundColor: MaterialStateProperty.all<Color>(AppColors.kraft),
          overlayColor: MaterialStateProperty.all<Color>(AppColors.amber.withOpacity(0.18)),
          shape: MaterialStateProperty.all<RoundedRectangleBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AppColors.sage, width: 1.4),
            ),
          ),
          padding: MaterialStateProperty.all<EdgeInsets>(
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          textStyle: MaterialStateProperty.all<TextStyle>(
            _interStyle(weight: FontWeight.w600, size: 15, letterSpacing: 0.6),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: MaterialStateProperty.all<Color>(AppColors.amber),
          overlayColor: MaterialStateProperty.all<Color>(AppColors.amber.withOpacity(0.1)),
          textStyle: MaterialStateProperty.all<TextStyle>(
            _interStyle(weight: FontWeight.w600, size: 15, letterSpacing: 0.6),
          ),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.charcoalSoft,
        titleTextStyle: _oswaldStyle(
          color: AppColors.kraft,
          weight: FontWeight.w600,
          size: 20,
        ),
        contentTextStyle: _interStyle(
          color: AppColors.kraft,
          size: 16,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.rust, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.charcoalSoft,
        selectedColor: AppColors.forest,
        disabledColor: AppColors.charcoalAlt,
        labelStyle: _interStyle(color: AppColors.kraft, size: 13),
        secondaryLabelStyle: _interStyle(color: AppColors.charcoal, size: 13),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.amber,
        tileColor: AppColors.charcoalSoft,
        textColor: AppColors.kraft,
        titleTextStyle: _interStyle(size: 16, weight: FontWeight.w600, color: AppColors.kraft),
        subtitleTextStyle: _interStyle(size: 14, color: AppColors.sage),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.sage.withOpacity(0.4), width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    );
  }

  static TextTheme _buildTextTheme(ColorScheme colorScheme) {
    return TextTheme(
      displayLarge: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 48,
        weight: FontWeight.w600,
        letterSpacing: 1.6,
      ),
      displayMedium: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 40,
        weight: FontWeight.w600,
        letterSpacing: 1.4,
      ),
      displaySmall: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 34,
        weight: FontWeight.w600,
        letterSpacing: 1.3,
      ),
      headlineLarge: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 30,
        weight: FontWeight.w600,
      ),
      headlineMedium: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 26,
        weight: FontWeight.w600,
      ),
      headlineSmall: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 22,
        weight: FontWeight.w600,
      ),
      titleLarge: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 20,
        weight: FontWeight.w600,
      ),
      titleMedium: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 18,
        weight: FontWeight.w500,
      ),
      titleSmall: _oswaldStyle(
        color: colorScheme.onBackground,
        size: 16,
        weight: FontWeight.w500,
      ),
      bodyLarge: _interStyle(
        color: colorScheme.onBackground,
        size: 18,
        letterSpacing: -0.05,
      ),
      bodyMedium: _interStyle(
        color: colorScheme.onBackground,
        size: 16,
        letterSpacing: -0.1,
      ),
      bodySmall: _interStyle(
        color: colorScheme.onBackground.withOpacity(0.85),
        size: 13,
      ),
      labelLarge: _spectralStyle(
        color: AppColors.rust,
        size: 12,
        weight: FontWeight.w600,
        letterSpacing: 2.4,
      ),
      labelMedium: _spectralStyle(
        color: AppColors.rust,
        size: 11,
        weight: FontWeight.w600,
        letterSpacing: 2.0,
      ),
      labelSmall: _spectralStyle(
        color: AppColors.rust,
        size: 10,
        weight: FontWeight.w600,
        letterSpacing: 1.8,
      ),
    );
  }

  static OutlineInputBorder _journalInputBorder({Color? color, double width = 1.0}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: color ?? AppColors.sage.withOpacity(0.6),
        width: width,
      ),
    );
  }
}
