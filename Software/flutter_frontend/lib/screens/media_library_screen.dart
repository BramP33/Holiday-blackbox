import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../layout.dart';
import '../models/media_item.dart';
import '../models/trash_entry.dart';
import '../state/app_environment.dart';
import '../state/providers.dart';
import '../theme.dart';
import '../utils/camp_name_generator.dart';
import '../widgets/journal_card.dart';
import '../widgets/polaroid_tile.dart';
import 'photo_viewer_screen.dart';
import 'video_player_screen.dart';

class MediaLibraryScreen extends ConsumerStatefulWidget {
  const MediaLibraryScreen({super.key});

  @override
  ConsumerState<MediaLibraryScreen> createState() => _MediaLibraryScreenState();
}

class _MediaLibraryScreenState extends ConsumerState<MediaLibraryScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _photoPage = 1;
  int _videoPage = 1;
  String? _videoQuery;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _isSearchExpanded = false;
  double _lastOffset = 0;
  bool _controlsVisible = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) {
          setState(() {});
        }
      });
    CampNameGenerator.instance.ensureLoaded();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.l10n;
    final labels = [
      loc.translate('media.library.tab.photo'),
      loc.translate('media.library.tab.video'),
      loc.translate('media.library.tab.trash'),
    ];
    final activeLabel = labels[_tabController.index.clamp(0, labels.length - 1)];
    final outer = ScreenLayout.outerPadding(context);
    final spacing = ScreenLayout.journalSpacing(context);
    final isCompact = ScreenLayout.isTargetSize(context);
    final cardPadding = isCompact ? const EdgeInsets.all(14) : ScreenLayout.journalPadding(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(outer.left, outer.top, outer.right, 0),
      child: Column(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, animation) => SizeTransition(
              sizeFactor: animation,
              axisAlignment: -1,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: _controlsVisible
                ? _HeaderControls(
                    key: const ValueKey('header-visible'),
                    spacing: spacing,
                    activeLabel: activeLabel,
                  )
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: JournalCard(
              padding: cardPadding,
              heroBadge: _BoardBadge(text: activeLabel.toUpperCase()),
              child: Column(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, animation) => SizeTransition(
                      sizeFactor: animation,
                      axisAlignment: -1,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: _controlsVisible
                        ? _TabControls(
                            key: const ValueKey('tabs-visible'),
                            spacing: spacing,
                            tabBuilder: () => _buildTabBar(context),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(
                    child: NotificationListener<UserScrollNotification>(
                      onNotification: (notification) {
                        final metrics = notification.metrics;
                        final delta = metrics.pixels - _lastOffset;
                        if (delta.abs() > 12) {
                          final userDirection = notification.direction;
                          final shouldHide = delta > 0 && userDirection == ScrollDirection.forward;
                          final shouldShow = delta < 0 && userDirection == ScrollDirection.reverse;
                          final clampedTop = metrics.pixels <= 0;

                          bool? nextVisible;
                          if (clampedTop || shouldShow) {
                            nextVisible = true;
                          } else if (shouldHide) {
                            nextVisible = false;
                          }

                          if (nextVisible != null && nextVisible != _controlsVisible) {
                            setState(() {
                              _controlsVisible = nextVisible!;
                            });
                          }
                        }
                        _lastOffset = metrics.pixels;
                        return false;
                      },
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildPhotosTab(context),
                          _buildVideosTab(context),
                          _buildTrashTab(context),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.charcoalSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sage.withOpacity(0.45), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: TabBar(
          controller: _tabController,
          indicatorPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          indicator: BoxDecoration(
            color: AppColors.forest.withOpacity(0.85),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.amber.withOpacity(0.75), width: 1.4),
          ),
          dividerColor: Colors.transparent,
          labelColor: AppColors.amber,
          unselectedLabelColor: AppColors.sage,
          tabs: const [
            Tab(icon: Icon(Icons.photo_library_outlined, size: 22)),
            Tab(icon: Icon(Icons.video_collection_outlined, size: 22)),
            Tab(icon: Icon(Icons.delete_outline, size: 22)),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotosTab(BuildContext context) {
    final photosAsync = ref.watch(photosProvider(_photoPage));
    final env = ref.watch(appEnvironmentProvider);
    final spacing = ScreenLayout.journalSpacing(context);
    final crossAxisCount = ScreenLayout.photoCrossAxisCount(context);
    final aspectRatio = ScreenLayout.photoAspectRatio(context);
    return photosAsync.when(
      data: (page) {
        if (page.items.isEmpty) {
          return _EmptyBoard(message: context.tr('media.library.photos.empty'));
        }
        return Column(
          children: [
            Expanded(
              child: GridView.builder(
                padding: EdgeInsets.only(bottom: spacing, top: 8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                  childAspectRatio: aspectRatio,
                ),
                itemCount: page.items.length,
                itemBuilder: (context, index) {
                  final item = page.items[index];
                  final pathSegments = item.path.split('/')..removeWhere((segment) => segment.isEmpty);
                  final title = pathSegments.isNotEmpty ? pathSegments.last : 'Photo';
                  final subtitle = pathSegments.length >= 2 ? pathSegments[pathSegments.length - 2] : 'Captured';
                  return PolaroidTile(
                    child: CachedNetworkImage(
                      imageUrl: item.buildPreviewUri(env.baseUri).toString(),
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(color: AppColors.charcoalAlt),
                      errorWidget: (context, url, error) => const Icon(Icons.broken_image, size: 32),
                    ),
                    title: title,
                    subtitle: subtitle,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => PhotoViewerScreen(item: item)),
                      );
                    },
                  );
                },
              ),
            ),
            PaginationControls(
              page: page.page,
              pageCount: page.pageCount,
              onNext: page.page < page.pageCount
                  ? () {
                      setState(() {
                        _photoPage += 1;
                      });
                    }
                  : null,
              onPrev: page.page > 1
                  ? () {
                      setState(() {
                        _photoPage -= 1;
                      });
                    }
                  : null,
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => _DisconnectedPlaceholder(
        variant: _PlaceholderVariant.photo,
        onRetry: () {
          ref.invalidate(photosProvider(_photoPage));
          setState(() {});
        },
      ),
    );
  }

  Widget _buildVideosTab(BuildContext context) {
    final request = VideoRequest(page: _videoPage, query: _videoQuery);
    final videosAsync = ref.watch(videosProvider(request));
    final env = ref.watch(appEnvironmentProvider);
    final spacing = ScreenLayout.journalSpacing(context);
    final isCompact = ScreenLayout.isTargetSize(context);
    final searchSpacing = spacing * (isCompact ? 0.45 : 0.6);

    return videosAsync.when(
      data: (page) {
        if (page.items.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: _VideoSearchControl(
                  expanded: _isSearchVisible,
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onSubmit: _applySearch,
                  onClear: _clearSearch,
                  onExpand: _expandSearch,
                  onCollapse: _collapseSearch,
                  hasQuery: _videoQuery?.isNotEmpty == true,
                ),
              ),
              SizedBox(height: searchSpacing),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: spacing * 0.4),
                  child: const _EmptyBoard(
                    message: 'No matching clips. Try another search or reset.',
                  ),
                ),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: _VideoSearchControl(
                expanded: _isSearchVisible,
                controller: _searchController,
                focusNode: _searchFocusNode,
                onSubmit: _applySearch,
                onClear: _clearSearch,
                onExpand: _expandSearch,
                onCollapse: _collapseSearch,
                hasQuery: _videoQuery?.isNotEmpty == true,
              ),
            ),
            SizedBox(height: searchSpacing),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.only(bottom: spacing * 0.5),
                itemCount: page.items.length,
                separatorBuilder: (_, __) => SizedBox(height: spacing - 6),
                itemBuilder: (context, index) {
                  final record = page.items[index];
                  final isFirst = index == 0;
                  final isLast = index == page.items.length - 1;
                  return _VideoTimelineEntry(
                    record: record,
                    baseUri: env.baseUri,
                    showTopConnector: !isFirst,
                    showBottomConnector: !isLast,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => VideoPlayerScreen(record: record)),
                      );
                    },
                    onDelete: () => _showDeleteVideoDialog(context, record),
                  );
                },
              ),
            ),
            PaginationControls(
              page: page.page,
              pageCount: page.pageCount,
              onNext: page.page < page.pageCount
                  ? () {
                      setState(() {
                        _videoPage += 1;
                      });
                    }
                  : null,
              onPrev: page.page > 1
                  ? () {
                        setState(() {
                          _videoPage -= 1;
                        });
                      }
                  : null,
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => _DisconnectedPlaceholder(
        variant: _PlaceholderVariant.video,
        onRetry: () {
          ref.invalidate(videosProvider(request));
          setState(() {});
        },
      ),
    );
  }

  Widget _buildTrashTab(BuildContext context) {
    final trashAsync = ref.watch(trashEntriesProvider);
    final spacing = ScreenLayout.journalSpacing(context);

    return trashAsync.when(
      data: (entries) {
        if (entries.isEmpty) {
          return _EmptyBoard(message: context.tr('media.library.trash.empty'));
        }
        return ListView.separated(
          padding: EdgeInsets.only(top: 8, bottom: spacing + 16),
          itemBuilder: (context, index) {
            final entry = entries[index];
            return _TrashEntryCard(
              entry: entry,
              spacing: spacing,
              onRestore: () async {
                final api = ref.read(apiClientProvider);
                try {
                  await api.restoreTrashEntry(entry.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.tr(
                            'media.library.trash.restore_success',
                            params: {'name': entry.filename},
                          ),
                        ),
                      ),
                    );
                  }
                  ref.invalidate(trashEntriesProvider);
                  ref.invalidate(videosProvider(VideoRequest(page: _videoPage, query: _videoQuery)));
                  ref.invalidate(photosProvider(_photoPage));
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.tr(
                            'media.library.trash.restore_failed',
                            params: {'error': error.toString()},
                          ),
                        ),
                      ),
                    );
                  }
                }
              },
              onDelete: () async {
                final confirm = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(context.tr('media.library.trash.delete_confirm_title')),
                        content: Text(
                          context.tr(
                            'media.library.trash.delete_confirm_body',
                            params: {'name': entry.filename},
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(dialogContext).pop(false),
                            child: Text(context.tr('media.library.common.cancel')),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(dialogContext).pop(true),
                            child: Text(context.tr('media.library.common.delete')),
                          ),
                        ],
                      ),
                    ) ??
                    false;
                if (!confirm) return;
                final api = ref.read(apiClientProvider);
                try {
                  await api.purgeTrashEntry(entry.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.tr(
                            'media.library.trash.delete_success',
                            params: {'name': entry.filename},
                          ),
                        ),
                      ),
                    );
                  }
                  ref.invalidate(trashEntriesProvider);
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.tr(
                            'media.library.trash.delete_failed',
                            params: {'error': error.toString()},
                          ),
                        ),
                      ),
                    );
                  }
                }
              },
            );
          },
          separatorBuilder: (_, __) => SizedBox(height: spacing),
          itemCount: entries.length,
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${context.tr('media.library.trash.error')}\n$error',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }

  void _applySearch(String value) {
    final trimmed = value.trim();
    setState(() {
      _videoQuery = trimmed.isEmpty ? null : trimmed;
      _videoPage = 1;
      _isSearchExpanded = trimmed.isNotEmpty;
    });
    if (trimmed.isNotEmpty) {
      _searchFocusNode.unfocus();
    }
  }

  void _clearSearch() {
    setState(() {
      _videoQuery = null;
      _searchController.clear();
      _videoPage = 1;
      _isSearchExpanded = false;
    });
    _searchFocusNode.unfocus();
  }

  bool get _isSearchVisible =>
      _isSearchExpanded || (_videoQuery?.isNotEmpty ?? false) || _searchController.text.isNotEmpty;

  void _expandSearch() {
    if (_isSearchExpanded) return;
    setState(() {
      _isSearchExpanded = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _collapseSearch() {
    if (!_isSearchExpanded) return;
    setState(() {
      _isSearchExpanded = false;
    });
    _searchFocusNode.unfocus();
  }

  void _showDeleteVideoDialog(BuildContext context, VideoRecord record) {
    showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.tr('media.library.delete.title')),
          content: Text(
            context.tr(
              'media.library.delete.confirmation',
              params: {'name': record.filename ?? record.path.split('/').last},
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.tr('common.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: AppColors.rust),
              child: Text(context.tr('common.delete')),
            ),
          ],
        );
      },
    ).then((confirmed) async {
      if (confirmed != true) return;
      
      final api = ref.read(apiClientProvider);
      try {
        await api.deleteMedia(record.path);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr(
                  'media.library.delete.success',
                  params: {'name': record.filename ?? record.path.split('/').last},
                ),
              ),
            ),
          );
          // Refresh the video list
          final request = VideoRequest(page: _videoPage, query: _videoQuery);
          ref.invalidate(videosProvider(request));
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr(
                  'media.library.delete.failed',
                  params: {'error': error.toString()},
                ),
              ),
            ),
          );
        }
      }
    });
  }
}

class _TabStatusChip extends StatelessWidget {
  const _TabStatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final isTarget = ScreenLayout.isTargetSize(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isTarget ? 14 : 16, vertical: isTarget ? 6 : 8),
      decoration: BoxDecoration(
        color: AppColors.kraft.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.rust.withOpacity(0.6), width: 1.3),
      ),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AppColors.amber),
      ),
    );
  }
}

class _HeaderControls extends StatelessWidget {
  const _HeaderControls({super.key, required this.spacing, required this.activeLabel});

  final double spacing;
  final String activeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCompact = ScreenLayout.isTargetSize(context);
    final iconEdge = isCompact ? 36.0 : 40.0;
    final verticalSpacing = spacing * (isCompact ? 0.4 : 0.6);
    return Padding(
      padding: EdgeInsets.only(bottom: verticalSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: iconEdge,
            height: iconEdge,
            decoration: BoxDecoration(
              color: AppColors.charcoalAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.rust.withOpacity(0.7), width: 1.4),
            ),
            child: const Icon(Icons.collections_bookmark_rounded, color: AppColors.amber, size: 22),
          ),
          SizedBox(width: isCompact ? 10 : 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('media.library.header'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: isCompact ? 2 : 4),
                Text(
                  context.tr('media.library.subtitle'),
                  style: theme.textTheme.bodySmall?.copyWith(color: AppColors.sage),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          SizedBox(width: isCompact ? 8 : 12),
          _TabStatusChip(label: activeLabel),
        ],
      ),
    );
  }
}

class _TabControls extends StatelessWidget {
  const _TabControls({super.key, required this.spacing, required this.tabBuilder});

  final double spacing;
  final Widget Function() tabBuilder;

  @override
  Widget build(BuildContext context) {
    final isCompact = ScreenLayout.isTargetSize(context);
    return Column(
      children: [
        tabBuilder(),
        SizedBox(height: spacing * (isCompact ? 0.25 : 0.4)),
      ],
    );
  }
}

class _BoardBadge extends StatelessWidget {
  const _BoardBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final isTarget = ScreenLayout.isTargetSize(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isTarget ? 14 : 16, vertical: isTarget ? 5 : 7),
      decoration: BoxDecoration(
        color: AppColors.amber,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.charcoal, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            offset: const Offset(0, 3),
            blurRadius: 10,
          ),
        ],
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AppColors.charcoal, letterSpacing: 1.1),
      ),
    );
  }
}

class _VideoSearchControl extends StatelessWidget {
  const _VideoSearchControl({
    required this.expanded,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onClear,
    required this.onExpand,
    required this.onCollapse,
    required this.hasQuery,
  });

  final bool expanded;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final isCompact = ScreenLayout.isTargetSize(context);
    final buttonSize = isCompact ? 44.0 : 48.0;
    final iconSize = isCompact ? 22.0 : 24.0;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        axisAlignment: -1,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: expanded
          ? _buildExpanded(context, isCompact)
          : _buildCollapsed(context, buttonSize, iconSize),
    );
  }

  Widget _buildCollapsed(BuildContext context, double size, double iconSize) {
    return Material(
      key: const ValueKey('search-collapsed'),
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onExpand,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: AppColors.charcoalAlt,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.search, size: iconSize, color: AppColors.amber),
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context, bool isCompact) {
    return Container(
      key: const ValueKey('search-expanded'),
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 12 : 14, vertical: isCompact ? 6 : 8),
      decoration: BoxDecoration(
        color: AppColors.charcoalAlt,
        borderRadius: BorderRadius.circular(isCompact ? 18 : 20),
        border: Border.all(color: AppColors.sage.withOpacity(0.5), width: 1.2),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, color: AppColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              focusNode: focusNode,
              controller: controller,
              onSubmitted: onSubmit,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: context.tr('media.library.search_placeholder'),
                isDense: true,
              ),
            ),
          ),
          if (hasQuery)
            IconButton(
              icon: const Icon(Icons.clear, color: AppColors.sage),
              onPressed: onClear,
            )
          else
            IconButton(
              icon: const Icon(Icons.close, color: AppColors.sage),
              onPressed: onCollapse,
            ),
        ],
      ),
    );
  }
}

class _VideoTimelineEntry extends StatelessWidget {
  const _VideoTimelineEntry({
    required this.record,
    required this.baseUri,
    required this.onTap,
    required this.showTopConnector,
    required this.showBottomConnector,
    this.onDelete,
  });

  final VideoRecord record;
  final Uri baseUri;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final bool showTopConnector;
  final bool showBottomConnector;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final captured = record.capturedAtDisplay ?? 'Unknown date';
    final recordingPlace = (record.locationLabel?.trim().isNotEmpty ?? false)
        ? record.locationLabel!.trim()
        : CampNameGenerator.instance.fallbackForKey(record.path);
    final folder = record.folder?.trim().isNotEmpty == true ? record.folder!.trim() : null;
    final durationValue = record.duration != null
        ? _formatDurationValue(record.duration!)
        : context.tr('media.library.duration_placeholder');
    final fileSizeValue = context.tr('media.library.filesize_placeholder');
    final isTarget = ScreenLayout.isTargetSize(context);
    final previewWidth = isTarget ? 120.0 : 140.0;
    final containerPadding = EdgeInsets.all(isTarget ? 16 : 18);
    final spacing = ScreenLayout.journalSpacing(context);
    final markerConnectorHeight = isTarget ? 22.0 : 24.0;
    final between = isTarget ? 14.0 : 18.0;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Column(
              children: [
                if (showTopConnector)
                  Container(width: 2, height: markerConnectorHeight, color: AppColors.sage.withOpacity(0.5)),
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AppColors.amber,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: AppColors.charcoal, width: 2),
                  ),
                ),
                if (showBottomConnector)
                  Container(width: 2, height: markerConnectorHeight + 10, color: AppColors.sage.withOpacity(0.5)),
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.charcoalAlt,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.rust.withOpacity(0.5), width: 1.4),
              ),
              padding: containerPadding,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: previewWidth,
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: CachedNetworkImage(
                          imageUrl: record.buildThumbnailUri(baseUri).toString(),
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(color: AppColors.charcoal),
                          errorWidget: (context, url, error) => const Icon(Icons.videocam_off),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: between),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.filename ?? record.path.split('/').last,
                          style: theme.textTheme.titleSmall,
                        ),
                        SizedBox(height: isTarget ? 4 : 6),
                        Text(
                          context.tr('media.library.recording_place', params: {'place': recordingPlace}),
                          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.amber),
                        ),
                        SizedBox(height: isTarget ? 2 : 4),
                        Text(
                          context.tr('media.library.captured_at', params: {'date': captured}),
                          style: theme.textTheme.bodySmall,
                        ),
                        if (folder != null) ...[
                          SizedBox(height: isTarget ? 2 : 4),
                          Text(
                            context.tr('media.library.folder', params: {'folder': folder}),
                            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.sage),
                          ),
                        ],
                        SizedBox(height: isTarget ? 6 : 8),
                        Text(
                          context.tr('media.library.duration', params: {'duration': durationValue}),
                          style: theme.textTheme.bodySmall,
                        ),
                        SizedBox(height: isTarget ? 2 : 4),
                        Text(
                          context.tr('media.library.filesize', params: {'size': fileSizeValue}),
                          style: theme.textTheme.bodySmall,
                        ),
                        if (record.transcriptAvailable || record.transcriptState != null)
                          Padding(
                            padding: EdgeInsets.only(top: isTarget ? 4 : 6),
                            child: Text(
                              _transcriptLabel(record),
                              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.sage),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(left: spacing * 0.2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onDelete != null)
                          InkWell(
                            onTap: onDelete,
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.delete_outline,
                                color: AppColors.rust,
                                size: 20,
                              ),
                            ),
                          ),
                        if (onDelete != null) SizedBox(height: 8),
                        const Icon(Icons.open_in_new, color: AppColors.amber),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _transcriptLabel(VideoRecord record) {
    if (record.transcriptAvailable) {
      return 'Transcript ready';
    }
    final state = record.transcriptState ?? 'pending';
    return 'Transcript: $state';
  }
}

class _TrashEntryCard extends StatelessWidget {
  const _TrashEntryCard({
    required this.entry,
    required this.spacing,
    required this.onRestore,
    required this.onDelete,
  });

  final TrashEntry entry;
  final double spacing;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badgeLabel = entry.isVideo
        ? context.tr('media.library.trash.badge.video')
        : entry.isPhoto
            ? context.tr('media.library.trash.badge.photo')
            : context.tr('media.library.trash.badge.file');
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.rust,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.charcoal, width: 2),
      ),
      child: Text(
        badgeLabel,
        style: theme.textTheme.labelMedium?.copyWith(color: AppColors.charcoal),
      ),
    );

    return JournalCard(
      heroBadge: badge,
      padding: ScreenLayout.journalPadding(context).copyWith(bottom: spacing - 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.charcoal,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.rust.withOpacity(0.7), width: 1.6),
                ),
                child: Icon(
                  entry.isVideo
                      ? Icons.video_library_outlined
                      : entry.isPhoto
                          ? Icons.photo_outlined
                          : Icons.insert_drive_file_outlined,
                  color: AppColors.amber,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.filename,
                      style: theme.textTheme.titleSmall?.copyWith(color: AppColors.kraft),
                    ),
                    if (entry.folder != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.folder!,
                        style: theme.textTheme.bodySmall?.copyWith(color: AppColors.sage),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (entry.sizeDisplay != null)
                          _MetaChip(icon: Icons.sd_card, label: entry.sizeDisplay!),
                        if (entry.trashedAtDisplay != null)
                          _MetaChip(icon: Icons.schedule, label: entry.trashedAtDisplay!),
                        _MetaChip(
                          icon: Icons.folder_open,
                          label: entry.originalRel ?? entry.storedRel,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: spacing - 10),
          Wrap(
            spacing: spacing - 12,
            runSpacing: spacing - 14,
            children: [
              FilledButton.icon(
                onPressed: onRestore,
                icon: const Icon(Icons.settings_backup_restore_rounded),
                label: Text(context.tr('media.library.trash.restore')),
              ),
              TextButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_forever_rounded),
                label: Text(context.tr('media.library.trash.delete')),
                style: TextButton.styleFrom(foregroundColor: AppColors.rust),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.charcoalAlt,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.sage.withOpacity(0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.amber),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _EmptyBoard extends StatelessWidget {
  const _EmptyBoard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final padding = ScreenLayout.isTargetSize(context) ? 20.0 : 24.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.sage),
        ),
      ),
    );
  }
}

enum _PlaceholderVariant { photo, video }

class _DisconnectedPlaceholder extends StatelessWidget {
  const _DisconnectedPlaceholder({required this.variant, required this.onRetry});

  final _PlaceholderVariant variant;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headline = variant == _PlaceholderVariant.photo
        ? context.tr('media.library.offline.photo_headline')
        : context.tr('media.library.offline.video_headline');
    final subtitle = variant == _PlaceholderVariant.photo
        ? context.tr('media.library.offline.photo_subtitle')
        : context.tr('media.library.offline.video_subtitle');
    final spacing = ScreenLayout.journalSpacing(context);
    final cardPadding = ScreenLayout.journalPadding(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : 480.0;
        final minHeight = (maxHeight - 24).clamp(320.0, double.infinity);
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: JournalCard(
                  padding: cardPadding,
                  heroBadge: const _BoardBadge(text: 'OFFLINE'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(headline, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(color: AppColors.sage, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      if (variant == _PlaceholderVariant.photo)
                        const _PhotoPlaceholderGrid()
                      else
                        const _VideoPlaceholderList(),
                      SizedBox(height: spacing - 4),
                      Wrap(
                        spacing: spacing - 6,
                        runSpacing: 12,
                        alignment: WrapAlignment.spaceBetween,
                        children: [
                          SizedBox(
                            width: 320,
                            child: Text(
                              context.tr('media.library.offline.hint'),
                              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.sage),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: onRetry,
                            icon: const Icon(Icons.refresh_rounded),
                            label: Text(context.tr('media.library.offline.retry')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PhotoPlaceholderGrid extends StatelessWidget {
  const _PhotoPlaceholderGrid();

  @override
  Widget build(BuildContext context) {
    final captions = ['Awaiting sync', 'Field log', 'Next capture', 'Deck ready', 'Holding spot', 'Travel frame'];
    final spacing = ScreenLayout.journalSpacing(context);
    final crossAxisCount = ScreenLayout.photoCrossAxisCount(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalSpacing = (crossAxisCount - 1) * spacing;
        final tileWidth = (constraints.maxWidth - totalSpacing) / crossAxisCount;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: List.generate(6, (index) {
            final caption = captions[index % captions.length];
            return SizedBox(
              width: tileWidth,
              child: PolaroidTile(
                width: tileWidth,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.charcoal,
                          AppColors.charcoalAlt,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: const Center(
                      child: Icon(Icons.photo_outlined, size: 48, color: AppColors.kraft),
                    ),
                  ),
                ),
                title: caption,
                subtitle: context.tr('media.library.placeholder.connect'),
              ),
            );
          }),
        );
      },
    );
  }
}

class _VideoPlaceholderList extends StatelessWidget {
  const _VideoPlaceholderList();

  @override
  Widget build(BuildContext context) {
    final spacing = ScreenLayout.journalSpacing(context);
    final isTarget = ScreenLayout.isTargetSize(context);
    final previewWidth = isTarget ? 120.0 : 140.0;
    final connectorShort = isTarget ? 20.0 : 24.0;

    return Column(
      children: List.generate(4, (index) {
        final isFirst = index == 0;
        final isLast = index == 3;
        final placeholderName = CampNameGenerator.instance.fallbackForKey('placeholder-$index');
        return Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : spacing - 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: Column(
                  children: [
                    if (!isFirst)
                      Container(width: 2, height: connectorShort, color: AppColors.sage.withOpacity(0.35)),
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: AppColors.amber,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: AppColors.charcoal, width: 2),
                      ),
                    ),
                    if (!isLast)
                      Container(width: 2, height: connectorShort + 10, color: AppColors.sage.withOpacity(0.35)),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.charcoalAlt,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.rust.withOpacity(0.4), width: 1.4),
                  ),
                  padding: EdgeInsets.all(isTarget ? 16 : 18),
                  child: Row(
                    children: [
                      Container(
                        width: previewWidth,
                        height: previewWidth * 9 / 16,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: LinearGradient(
                            colors: [
                              AppColors.forest.withOpacity(0.7),
                              AppColors.forest.withOpacity(0.3),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: const Icon(Icons.videocam_outlined, color: AppColors.kraft, size: 36),
                      ),
                      SizedBox(width: isTarget ? 14 : 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.tr(
                                'media.library.recording_place',
                                params: {'place': placeholderName},
                              ),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            SizedBox(height: isTarget ? 4 : 6),
                            Text(
                              context.tr(
                                'media.library.duration',
                                params: {
                                  'duration': context.tr('media.library.duration_placeholder'),
                                },
                              ),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.sage),
                            ),
                            SizedBox(height: isTarget ? 2 : 4),
                            Text(
                              context.tr(
                                'media.library.filesize',
                                params: {
                                  'size': context.tr('media.library.filesize_placeholder'),
                                },
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

class PaginationControls extends StatelessWidget {
  const PaginationControls({
    super.key,
    required this.page,
    required this.pageCount,
    required this.onNext,
    required this.onPrev,
  });

  final int page;
  final int pageCount;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;

  @override
  Widget build(BuildContext context) {
    final spacing = ScreenLayout.journalSpacing(context);
    return Padding(
      padding: EdgeInsets.only(top: spacing - 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left),
            label: Text(context.tr('media.library.pagination.prev')),
          ),
          SizedBox(width: spacing - 10),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: spacing > 24 ? 8 : 6),
            decoration: BoxDecoration(
              color: AppColors.kraft.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.rust.withOpacity(0.6), width: 1.2),
            ),
            child: Text(
              context.tr(
                'media.library.pagination.label',
                params: {'page': '$page', 'pages': '$pageCount'},
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.kraft),
            ),
          ),
          SizedBox(width: spacing - 10),
          OutlinedButton.icon(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
            label: Text(context.tr('media.library.pagination.next')),
          ),
        ],
      ),
    );
  }
}

String _formatDurationValue(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}
