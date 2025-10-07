import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../layout.dart';
import '../theme.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.iconAsset = 'assets/icons/trail/trail_marker.svg',
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final String iconAsset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTarget = ScreenLayout.isTargetSize(context);
    final iconEdge = isTarget ? 36.0 : 40.0;
    final horizontalSpacing = isTarget ? 12.0 : 16.0;
    final dividerSpacing = isTarget ? 18.0 : 22.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: iconEdge,
              height: iconEdge,
              padding: EdgeInsets.all(isTarget ? 6 : 8),
              decoration: BoxDecoration(
                color: AppColors.charcoal,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.rust, width: 2),
              ),
              child: SvgPicture.asset(iconAsset, fit: BoxFit.contain),
            ),
            SizedBox(width: horizontalSpacing),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(letterSpacing: 1.2),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: EdgeInsets.only(top: isTarget ? 2 : 4),
                      child: Text(
                        subtitle!,
                        style: theme.textTheme.labelLarge?.copyWith(color: AppColors.amber),
                      ),
                    ),
                ],
              ),
            ),
            if (action != null) ...[
              SizedBox(width: horizontalSpacing),
              action!,
            ],
          ],
        ),
        SizedBox(height: isTarget ? 8 : 10),
        Container(
          height: 3,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: LinearGradient(
              colors: [
                AppColors.rust.withOpacity(0.0),
                AppColors.rust.withOpacity(0.65),
                AppColors.amber.withOpacity(0.8),
                AppColors.rust.withOpacity(0.0),
              ],
              stops: const [0.0, 0.18, 0.82, 1.0],
            ),
          ),
        ),
        SizedBox(height: dividerSpacing * 0.35),
      ],
    );
  }
}
