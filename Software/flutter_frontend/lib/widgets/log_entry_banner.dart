import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../layout.dart';
import '../theme.dart';

class LogEntryBanner extends StatelessWidget {
  const LogEntryBanner({
    super.key,
    required this.title,
    required this.message,
    required this.timestamp,
    this.iconAsset = 'assets/icons/trail/trail_marker.svg',
  });

  final String title;
  final String message;
  final DateTime timestamp;
  final String iconAsset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeString = DateFormat('HH:mm').format(timestamp);
    final isTarget = ScreenLayout.isTargetSize(context);
    final padding = EdgeInsets.symmetric(horizontal: 20, vertical: isTarget ? 14 : 16);
    final glyphSize = isTarget ? 44.0 : 52.0;
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      color: AppColors.charcoal,
      fontSize: isTarget ? 16 : null,
    );
    final messageStyle = theme.textTheme.bodyMedium?.copyWith(
      color: AppColors.charcoal,
      height: 1.4,
      fontSize: isTarget ? 14 : null,
    );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.amber.withOpacity(0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.rust, width: 2.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            offset: const Offset(0, 6),
            blurRadius: 18,
          ),
        ],
      ),
      padding: padding,
      child: Row(
        children: [
          Container(
            width: glyphSize,
            height: glyphSize,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.charcoal,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.rust, width: 1.6),
            ),
            child: SvgPicture.asset(iconAsset, fit: BoxFit.contain),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: titleStyle),
                SizedBox(height: isTarget ? 4 : 6),
                Text(message, style: messageStyle),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'LOG',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: AppColors.charcoal,
                  letterSpacing: 3,
                  fontSize: isTarget ? 11 : null,
                ),
              ),
              Text(
                timeString,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.charcoal,
                  fontSize: isTarget ? 16 : 18,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
