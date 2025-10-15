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
import '../widgets/journal_card.dart';
import '../widgets/polaroid_tile.dart';
import 'photo_viewer_screen.dart';
import 'video_player_screen.dart';

class MediaLibraryScreen extends ConsumerStatefulWidget {
  const MediaLibraryScreen({super.key});

  @override
  ConsumerState<MediaLibraryScreen> createState() => _MediaLibraryScreenState();
}

class _MediaLibraryScreenState extends ConsumerState<MediaLibraryScreen>
    with SingleTickerProviderStateMixin {
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
    final activeLabel =
        labels[_tabController.index.clamp(0, labels.length - 1)];
    final outer = ScreenLayout.outerPadding(context);
    final spacing = ScreenLayout.journalSpacing(context);
    final isCompact = ScreenLayout.isTargetSize(context);
    final cardPadding = isCompact
        ? const EdgeInsets.all(14)
        : ScreenLayout.journalPadding(context);

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
                          final shouldHide = delta > 0 &&
                              userDirection == ScrollDirection.forward;
                          final shouldShow = delta < 0 &&
                              userDirection == ScrollDirection.reverse;
                          final clampedTop = metrics.pixels <= 0;

                          bool? nextVisible;
                          if (clampedTop || shouldShow) {
                            nextVisible = true;
                          } else if (shouldHide) {
                            nextVisible = false;
                          }

                          if (nextVisible != null &&
                              nextVisible != _controlsVisible) {
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
          indicatorPadding:
              const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          indicator: BoxDecoration(
            color: AppColors.forest.withOpacity(0.85),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: AppColors.amber.withOpacity(0.75), width: 1.4),
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
                  final pathSegments = item.path.split('/')
                    ..removeWhere((segment) => segment.isEmpty);
                  final title =
                      pathSegments.isNotEmpty ? pathSegments.last : 'Photo';
                  final subtitle = pathSegments.length >= 2
                      ? pathSegments[pathSegments.length - 2]
                      : 'Captured';
                  return PolaroidTile(
                    child: CachedNetworkImage(
                      imageUrl: item.buildPreviewUri(env.baseUri).toString(),
                      fit: BoxFit.cover,
                      placeholder: (context, url) =>
                          Container(color: AppColors.charcoalAlt),
                      errorWidget: (context, url, error) =>
                          const Icon(Icons.broken_image, size: 32),
                    ),
                    title: title,
                    subtitle: subtitle,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => PhotoViewerScreen(item: item)),
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
    const gridColumns = 2;

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
              child: GridView.builder(
                padding: EdgeInsets.only(bottom: spacing, top: 8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: gridColumns,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                  childAspectRatio: isCompact ? 0.82 : 0.88,
                ),
                itemCount: page.items.length,
                itemBuilder: (context, index) {
                  final record = page.items[index];
                  return _VideoGridCard(
                    record: record,
                    baseUri: env.baseUri,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => VideoPlayerScreen(record: record)),
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
                  ref.invalidate(videosProvider(
                      VideoRequest(page: _videoPage, query: _videoQuery)));
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
                        title: Text(context
                            .tr('media.library.trash.delete_confirm_title')),
                        content: Text(
                          context.tr(
                            'media.library.trash.delete_confirm_body',
                            params: {'name': entry.filename},
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child:
                                Text(context.tr('media.library.common.cancel')),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child:
                                Text(context.tr('media.library.common.delete')),
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
      _isSearchExpanded ||
      (_videoQuery?.isNotEmpty ?? false) ||
      _searchController.text.isNotEmpty;

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
    showDialog<String>(
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
              onPressed: () => Navigator.of(context).pop(null),
              child: Text(context.tr('common.cancel')),
            ),
            if (record.transcriptAvailable)
              TextButton(
                onPressed: () => Navigator.of(context).pop('transcript'),
                style: TextButton.styleFrom(foregroundColor: AppColors.amber),
                child: Text('Verwijder alleen transcript'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('media'),
              style: TextButton.styleFrom(foregroundColor: AppColors.rust),
              child: Text(context.tr('common.delete')),
            ),
          ],
        );
      },
    ).then((action) async {
      if (action == null) return;

      final api = ref.read(apiClientProvider);
      try {
        if (action == 'transcript') {
          // Delete only the transcript
          await api.deleteTranscript(record.path);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    'Transcript verwijderd voor ${record.filename ?? record.path.split('/').last}'),
              ),
            );
            // Refresh the video list
            final request = VideoRequest(page: _videoPage, query: _videoQuery);
            ref.invalidate(videosProvider(request));
          }
        } else if (action == 'media') {
          // Delete the entire media file
          await api.deleteMedia(record.path);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  context.tr(
                    'media.library.delete.success',
                    params: {
                      'name': record.filename ?? record.path.split('/').last
                    },
                  ),
                ),
              ),
            );
            // Refresh the video list
            final request = VideoRequest(page: _videoPage, query: _videoQuery);
            ref.invalidate(videosProvider(request));
          }
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
      padding: EdgeInsets.symmetric(
          horizontal: isTarget ? 14 : 16, vertical: isTarget ? 6 : 8),
      decoration: BoxDecoration(
        color: AppColors.kraft.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.rust.withOpacity(0.6), width: 1.3),
      ),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: AppColors.amber),
      ),
    );
  }
}

class _HeaderControls extends StatelessWidget {
  const _HeaderControls(
      {super.key, required this.spacing, required this.activeLabel});

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
              border: Border.all(
                  color: AppColors.rust.withOpacity(0.7), width: 1.4),
            ),
            child: const Icon(Icons.collections_bookmark_rounded,
                color: AppColors.amber, size: 22),
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
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.sage),
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
  const _TabControls(
      {super.key, required this.spacing, required this.tabBuilder});

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
      padding: EdgeInsets.symmetric(
          horizontal: isTarget ? 14 : 16, vertical: isTarget ? 5 : 7),
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
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: AppColors.charcoal, letterSpacing: 1.1),
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
      padding: EdgeInsets.symmetric(
          horizontal: isCompact ? 12 : 14, vertical: isCompact ? 6 : 8),
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

class _VideoGridCard extends StatelessWidget {
  const _VideoGridCard({
    required this.record,
    required this.baseUri,
    required this.onTap,
    required this.onDelete,
  });

  final VideoRecord record;
  final Uri baseUri;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flag = _flagEmojiForCode(record.countryCode);
    final tooltipLabel = record.locationLabel?.isNotEmpty == true
        ? record.locationLabel!
        : (record.countryCode?.isNotEmpty == true
            ? record.countryCode
            : 'Onbekende locatie');
    final durationValue = record.duration != null
        ? _formatDurationValue(record.duration!)
        : context.tr('media.library.duration_placeholder');
    final sizeLabel = _fileSizeLabel(record);
    final indicator = _TranscriptIndicator.fromRecord(record);

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Material(
        color: AppColors.charcoalAlt,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onTap,
              splashColor: AppColors.amber.withOpacity(0.18),
              highlightColor: AppColors.amber.withOpacity(0.12),
              child: Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CachedNetworkImage(
                      imageUrl: record.buildThumbnailUri(baseUri).toString(),
                      fit: BoxFit.cover,
                      placeholder: (context, url) =>
                          Container(color: AppColors.charcoal),
                      errorWidget: (context, url, error) => const Icon(
                          Icons.videocam_off,
                          size: 42,
                          color: AppColors.sage),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Tooltip(
                      message: indicator.tooltip,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: indicator.backgroundColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: indicator.borderColor, width: 1.2),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x55000000),
                              offset: Offset(0, 2),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            Icons.description_rounded,
                            color: indicator.iconColor,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 12,
                    bottom: 12,
                    child: Icon(
                      Icons.play_circle_fill_rounded,
                      color: Colors.white70,
                      size: 34,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _VideoMetaPill(
                    icon: Icons.schedule_rounded,
                    label: durationValue,
                  ),
                  Tooltip(
                    message: tooltipLabel,
                    child: flag != null
                        ? Text(
                            flag,
                            style: const TextStyle(
                              fontSize: 22,
                              fontFamily: 'Noto Color Emoji',
                            ),
                          )
                        : const Icon(Icons.public,
                            color: AppColors.sage, size: 18),
                  ),
                  _VideoMetaPill(
                    icon: Icons.sd_card_rounded,
                    label: sizeLabel,
                  ),
                ],
              ),
            ),
            Divider(
              height: 0.5,
              thickness: 0.5,
              color: AppColors.charcoal.withOpacity(0.45),
            ),
            InkWell(
              onTap: onDelete,
              splashColor: AppColors.rust.withOpacity(0.2),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.rust.withOpacity(0.16),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.delete_outline, color: AppColors.rust, size: 18),
                    const SizedBox(width: 5),
                    Text(
                      context.tr('common.delete'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.rust,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoMetaPill extends StatelessWidget {
  const _VideoMetaPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.charcoal.withOpacity(0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.sage.withOpacity(0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.amber),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.kraft),
          ),
        ],
      ),
    );
  }
}

class _TranscriptIndicator {
  const _TranscriptIndicator({
    required this.iconColor,
    required this.backgroundColor,
    required this.borderColor,
    required this.tooltip,
  });

  final Color iconColor;
  final Color backgroundColor;
  final Color borderColor;
  final String tooltip;

  factory _TranscriptIndicator.fromRecord(VideoRecord record) {
    final state = record.transcriptState?.toLowerCase().trim();
    if (record.transcriptAvailable) {
      return _TranscriptIndicator(
        iconColor: Colors.white,
        backgroundColor: const Color(0x33000000),
        borderColor: Colors.white70,
        tooltip: 'Transcriptie gereed',
      );
    }
    if (state == 'error' || state == 'failed') {
      return _TranscriptIndicator(
        iconColor: AppColors.rust,
        backgroundColor: AppColors.rust.withOpacity(0.18),
        borderColor: AppColors.rust.withOpacity(0.6),
        tooltip: 'Transcriptie mislukt',
      );
    }
    return _TranscriptIndicator(
      iconColor: AppColors.amber,
      backgroundColor: AppColors.amber.withOpacity(0.18),
      borderColor: AppColors.amber.withOpacity(0.6),
      tooltip: 'Transcriptie in wachtrij',
    );
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
      padding:
          ScreenLayout.journalPadding(context).copyWith(bottom: spacing - 4),
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
                  border: Border.all(
                      color: AppColors.rust.withOpacity(0.7), width: 1.6),
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
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: AppColors.kraft),
                    ),
                    if (entry.folder != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.folder!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.sage),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (entry.sizeDisplay != null)
                          _MetaChip(
                              icon: Icons.sd_card, label: entry.sizeDisplay!),
                        if (entry.trashedAtDisplay != null)
                          _MetaChip(
                              icon: Icons.schedule,
                              label: entry.trashedAtDisplay!),
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
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: AppColors.sage),
        ),
      ),
    );
  }
}

enum _PlaceholderVariant { photo, video }

class _DisconnectedPlaceholder extends StatelessWidget {
  const _DisconnectedPlaceholder(
      {required this.variant, required this.onRetry});

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
        final maxHeight =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 480.0;
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
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.sage, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      if (variant == _PlaceholderVariant.photo)
                        const _PhotoPlaceholderGrid()
                      else
                        const _VideoPlaceholderGrid(),
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
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: AppColors.sage),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: onRetry,
                            icon: const Icon(Icons.refresh_rounded),
                            label:
                                Text(context.tr('media.library.offline.retry')),
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
    final captions = [
      'Awaiting sync',
      'Field log',
      'Next capture',
      'Deck ready',
      'Holding spot',
      'Travel frame'
    ];
    final spacing = ScreenLayout.journalSpacing(context);
    final crossAxisCount = ScreenLayout.photoCrossAxisCount(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalSpacing = (crossAxisCount - 1) * spacing;
        final tileWidth =
            (constraints.maxWidth - totalSpacing) / crossAxisCount;

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
                      child: Icon(Icons.photo_outlined,
                          size: 48, color: AppColors.kraft),
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

class _VideoPlaceholderGrid extends StatelessWidget {
  const _VideoPlaceholderGrid();

  @override
  Widget build(BuildContext context) {
    final spacing = ScreenLayout.journalSpacing(context);
    const columns = 2;
    final examples = ['NL', 'DE', 'FR', 'NO'];

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : ScreenLayout.targetWidth.toDouble();
        final tileWidth = (maxWidth - (columns - 1) * spacing) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: List.generate(examples.length, (index) {
            final code = examples[index % examples.length];
            final flag = _flagEmojiForCode(code) ?? '🏕️';
            return SizedBox(
              width: tileWidth,
              child: _VideoPlaceholderCard(flag: flag),
            );
          }),
        );
      },
    );
  }
}

class _VideoPlaceholderCard extends StatelessWidget {
  const _VideoPlaceholderCard({required this.flag});

  final String flag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durationPlaceholder =
        context.tr('media.library.duration_placeholder');
    final sizePlaceholder = context.tr('media.library.filesize_placeholder');
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.charcoalAlt,
          border:
              Border.all(color: AppColors.rust.withOpacity(0.35), width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.charcoal, AppColors.charcoalAlt],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.videocam_outlined,
                      color: AppColors.kraft, size: 38),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.center,
                    child: Text(
                      flag,
                      style: const TextStyle(
                        fontSize: 30,
                        fontFamily: 'Noto Color Emoji',
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _VideoMetaPill(
                          icon: Icons.schedule_rounded,
                          label: durationPlaceholder),
                      _VideoMetaPill(
                          icon: Icons.sd_card_rounded, label: sizePlaceholder),
                    ],
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: AppColors.charcoal.withOpacity(0.4),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: AppColors.rust.withOpacity(0.12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.delete_outline, color: AppColors.rust),
                  const SizedBox(width: 8),
                  Text(
                    context.tr('common.delete'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.rust,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
            padding: EdgeInsets.symmetric(
                horizontal: 16, vertical: spacing > 24 ? 8 : 6),
            decoration: BoxDecoration(
              color: AppColors.kraft.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.rust.withOpacity(0.6), width: 1.2),
            ),
            child: Text(
              context.tr(
                'media.library.pagination.label',
                params: {'page': '$page', 'pages': '$pageCount'},
              ),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.kraft),
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

String? _flagEmojiForCode(String? code) {
  if (code == null || code.length != 2) return null;
  final normalized = code.toUpperCase();
  final first = normalized.codeUnitAt(0);
  final second = normalized.codeUnitAt(1);
  if (first < 65 || first > 90 || second < 65 || second > 90) {
    return null;
  }
  const base = 0x1F1E6;
  final firstFlag = base + (first - 65);
  final secondFlag = base + (second - 65);
  return String.fromCharCodes([firstFlag, secondFlag]);
}

String _fileSizeLabel(VideoRecord record) {
  final display = record.sizeDisplay;
  if (display != null && display.trim().isNotEmpty) {
    return display;
  }
  final bytes = record.sizeBytes;
  if (bytes != null && bytes > 0) {
    return _formatFileSize(bytes);
  }
  return '--';
}

String _formatFileSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  for (final unit in units) {
    if (value < 1024 || unit == units.last) {
      if (unit == 'B') {
        return '${value.toInt()} $unit';
      }
      return '${value.toStringAsFixed(1)} $unit';
    }
    value /= 1024;
  }
  return '$bytes B';
}
