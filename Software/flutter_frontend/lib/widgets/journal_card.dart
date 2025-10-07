import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';

class JournalCard extends StatelessWidget {
  const JournalCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.surfaceColor,
    this.textureOpacity = 0.2,
    this.heroBadge,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? surfaceColor;
  final double textureOpacity;
  final Widget? heroBadge;

  @override
  Widget build(BuildContext context) {
    final isTarget = ScreenLayout.isTargetSize(context);
    final blurRadius = isTarget ? 24.0 : 32.0;
    final offsetY = isTarget ? 8.0 : 12.0;
    final borderWidth = isTarget ? 1.2 : 1.6;
    final innerBorderWidth = isTarget ? 0.9 : 1.1;
    final background = (surfaceColor ?? AppColors.charcoalSoft).withOpacity(0.98);
    final decoration = BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.sage.withOpacity(0.55), width: borderWidth),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.45),
          offset: Offset(0, offsetY),
          blurRadius: blurRadius,
          spreadRadius: -12,
        ),
      ],
      image: DecorationImage(
        image: const AssetImage('assets/textures/topo.png'),
        fit: BoxFit.cover,
        colorFilter: ColorFilter.mode(
          AppColors.charcoal.withOpacity(1 - textureOpacity.clamp(0.0, 1.0)),
          BlendMode.srcATop,
        ),
      ),
    );

    final card = Container(
      decoration: decoration,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.charcoal.withOpacity(0.35), width: innerBorderWidth),
        ),
        padding: padding,
        child: DefaultTextStyle.merge(
          style: Theme.of(context).textTheme.bodyMedium,
          child: child,
        ),
      ),
    );

    if (heroBadge == null) {
      return card;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        Positioned(
          top: -16,
          left: 20,
          child: heroBadge!,
        ),
      ],
    );
  }
}
