import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';

class InfoTile extends StatelessWidget {
  const InfoTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.caption,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTarget = ScreenLayout.isTargetSize(context);
    final valueStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: isTarget ? 20 : 22,
      color: AppColors.kraft,
    );
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      color: AppColors.amber,
      fontSize: isTarget ? 11 : null,
    );
    final captionStyle = theme.textTheme.bodySmall?.copyWith(
      color: AppColors.sage,
      height: 1.3,
      fontSize: isTarget ? 12 : null,
    );
    final strapHeight = isTarget ? 6.0 : 8.0;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.kraft.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.rust.withOpacity(0.6), width: 1.6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                offset: Offset(0, isTarget ? 4 : 6),
                blurRadius: isTarget ? 14 : 18,
              ),
            ],
          ),
          padding: EdgeInsets.fromLTRB(20, isTarget ? 26 : 30, 20, isTarget ? 18 : 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: isTarget ? 36 : 40,
                height: isTarget ? 36 : 40,
                decoration: BoxDecoration(
                  color: AppColors.charcoal,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.rust, width: 1.6),
                ),
                child: Icon(icon, color: AppColors.amber, size: isTarget ? 22 : 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: valueStyle),
                    SizedBox(height: isTarget ? 4 : 6),
                    Text(label, style: labelStyle),
                    if (caption != null) ...[
                      SizedBox(height: isTarget ? 6 : 8),
                      Text(caption!, style: captionStyle),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: -12,
          left: 32,
          right: 32,
          child: Container(
            height: strapHeight,
            decoration: BoxDecoration(
              color: AppColors.rust.withOpacity(0.85),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.45),
                  offset: const Offset(0, 2),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
