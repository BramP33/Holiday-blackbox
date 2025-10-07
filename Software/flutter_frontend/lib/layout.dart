import 'package:flutter/widgets.dart';

class ScreenLayout {
  static const double targetWidth = 800;
  static const double targetHeight = 480;
  static const double compactAllowance = 80;

  static Size _sizeOf(BuildContext context) => MediaQuery.sizeOf(context);

  static bool isTargetSize(BuildContext context) => isTargetSizeFor(_sizeOf(context));

  static bool isTargetSizeFor(Size size) {
    final longest = size.longestSide;
    final shortest = size.shortestSide;
    return longest <= targetWidth + compactAllowance && shortest <= targetHeight + compactAllowance;
  }

  static bool isUltraCompact(BuildContext context) => isUltraCompactFor(_sizeOf(context));

  static bool isUltraCompactFor(Size size) {
    final longest = size.longestSide;
    final shortest = size.shortestSide;
    return longest <= targetWidth && shortest <= targetHeight;
  }

  static double horizontalPadding(BuildContext context) => isTargetSize(context) ? 18 : 24;

  static double verticalPadding(BuildContext context) => isTargetSize(context) ? 18 : 28;

  static EdgeInsets outerPadding(BuildContext context) {
    final h = horizontalPadding(context);
    final v = verticalPadding(context);
    return EdgeInsets.fromLTRB(h, v, h, 0);
  }

  static EdgeInsets journalPadding(BuildContext context) {
    final base = isTargetSize(context) ? 18.0 : 24.0;
    return EdgeInsets.all(base);
  }

  static double journalSpacing(BuildContext context) => isTargetSize(context) ? 20 : 28;

  static double gaugeSizeForWidth(double width) {
    if (width <= 780) return 180;
    if (width <= 960) return 210;
    return 240;
  }

  static int photoCrossAxisCount(BuildContext context) {
    final width = _sizeOf(context).width;
    if (width <= 860) return 2;
    if (width >= 1200) return 4;
    return 3;
  }

  static double photoAspectRatio(BuildContext context) => isTargetSize(context) ? 0.78 : 0.72;

  static double textScaleForSize(Size size) {
    if (isUltraCompactFor(size)) return 0.94;
    if (isTargetSizeFor(size)) return 0.97;
    return 1.0;
  }
}
