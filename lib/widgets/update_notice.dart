import 'dart:async';

import 'package:flutter/material.dart';

import '../services/update_checker.dart';
import '../theme/app_colors.dart';

/// The update offer on the phone, which has no banner strip.
///
/// Quiet until the checker has something to offer, so the page is unchanged
/// while the build is current.
class UpdateNotice extends StatelessWidget {
  const UpdateNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdatePhase?>(
      valueListenable: UpdateChecker.update,
      builder: (context, phase, _) {
        if (phase == null || phase is UpdateChecking) {
          return const SizedBox.shrink();
        }
        late final String title;
        late final String subtitle;
        var action = '';
        VoidCallback? onTap;
        switch (phase) {
          case final UpdateAvailable offer:
            title = 'Sector Scout ${offer.info.versionText} is available';
            subtitle = 'Downloads the APK and hands it to Android to install.';
            action = 'Update';
            onTap = () => unawaited(UpdateChecker.install(offer.info));
          case final UpdateDownloading download:
            title = 'Downloading ${download.info.versionText}';
            subtitle = '${download.percent}%';
          case final UpdateReady ready:
            title = '${ready.info.versionText} is downloaded';
            subtitle = 'Android asks for the install next — allow it there.';
            action = 'Install';
            onTap = () => unawaited(UpdateChecker.openReady(ready.filePath));
          case final UpdateFailed failed:
            title = 'Update failed';
            subtitle = failed.message;
            action = 'Try again';
            onTap = () => unawaited(UpdateChecker.refresh());
          case UpdateChecking():
            break;
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppColors.radius),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.system_update_alt_rounded,
                  size: 18,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                      if (phase is UpdateDownloading)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: LinearProgressIndicator(
                            value: phase.percent / 100,
                            backgroundColor: AppColors.border,
                          ),
                        ),
                    ],
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onTap,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.background,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(action),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
