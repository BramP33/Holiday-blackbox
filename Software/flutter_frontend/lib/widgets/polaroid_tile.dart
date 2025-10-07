import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';

class PolaroidTile extends StatelessWidget {
  const PolaroidTile({
    super.key,
    required this.child,
    required this.title,
    this.subtitle,
    this.onTap,
    this.width,
    this.pinColor = AppColors.rust,
  });

  final Widget child;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final double? width;
  final Color pinColor;

  @override
  Widget build(BuildContext context) {
    final isTarget = ScreenLayout.isTargetSize(context);

    return SizedBox(
      width: width ?? double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final effectiveWidth = width ?? constraints.maxWidth;
          final elevationBlur = isTarget ? 14.0 : 20.0;
          final elevationOffset = isTarget ? 6.0 : 8.0;
          final titleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.charcoal,
                fontWeight: FontWeight.w600,
                fontSize: isTarget ? 14 : null,
              );
          final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.sage,
                fontSize: isTarget ? 12 : null,
              );
          final card = Container(
            width: effectiveWidth,
            decoration: BoxDecoration(
              color: AppColors.kraft.withOpacity(0.92),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.35),
                  offset: Offset(0, elevationOffset),
                  blurRadius: elevationBlur,
                ),
              ],
              border: Border.all(color: AppColors.rust.withOpacity(0.4), width: 1.6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  child: child,
                ),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: isTarget ? 12 : 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.82),
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: titleStyle,
                      ),
                      if (subtitle != null) ...[
                        SizedBox(height: isTarget ? 2 : 4),
                        Text(
                          subtitle!,
                          style: subtitleStyle,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );

          final pinnedCard = Stack(
            clipBehavior: Clip.none,
            children: [
              card,
              Positioned(
                top: -10,
                left: effectiveWidth / 2 - 12,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: pinColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        offset: Offset(0, isTarget ? 2 : 3),
                        blurRadius: isTarget ? 4 : 6,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(Icons.push_pin, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          );

          if (onTap == null) {
            return pinnedCard;
          }
          return GestureDetector(onTap: onTap, child: pinnedCard);
        },
      ),
    );
  }
}
