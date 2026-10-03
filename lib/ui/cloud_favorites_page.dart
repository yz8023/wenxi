import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../data/cloud_favorites.dart';
import '../domain/models.dart';
import 'browser_page.dart';
import 'common.dart';

Future<void> openCloudFavorite(
  BuildContext context,
  AppServices services,
  CloudFavorite favorite,
) async {
  final value = await busy(
    context,
    () => services.favorites.open(favorite),
    label: '正在打开收藏位置…',
  );
  if (value == null || !context.mounted) return;
  await Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => BrowserPage(
        services,
        value.session,
        initialItems: value.files,
        initialTrail: value.trail,
        highlightedFileId: value.highlight,
      ),
    ),
  );
}

class CloudFavoritesPage extends StatefulWidget {
  const CloudFavoritesPage(
    this.services, {
    super.key,
    this.platform,
    this.accountId,
  });
  final AppServices services;
  final CloudPlatform? platform;
  final String? accountId;
  @override
  State<CloudFavoritesPage> createState() => _CloudFavoritesPageState();
}

class _CloudFavoritesPageState extends State<CloudFavoritesPage> {
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(CloudFavorite favorite) =>
      openCloudFavorite(context, widget.services, favorite);

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '网盘收藏',
    child: AnimatedBuilder(
      animation: widget.services.store,
      builder: (context, _) {
        final query = _search.text.trim().toLowerCase();
        final favorites = widget.services.favorites.all
            .where(
              (f) =>
                  (widget.platform == null ||
                      widget.platform == f.session.platform) &&
                  (widget.accountId == null ||
                      widget.accountId == f.session.accountId) &&
                  (query.isEmpty ||
                      f.file.name.toLowerCase().contains(query) ||
                      (f.isShareLink &&
                          (f.session.sourceLink?.url.toLowerCase().contains(
                                query,
                              ) ??
                              false)) ||
                      f.location.toLowerCase().contains(query)),
            )
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '搜索收藏名称、目录或分享链接',
                  prefixIcon: Icon(CupertinoIcons.search, size: 19),
                ),
              ),
            ),
            Expanded(
              child: favorites.isEmpty
                  ? const EmptyPanel(
                      '暂无收藏',
                      '可收藏文件、文件夹，也可在解析结果顶部收藏分享链接。',
                      icon: CupertinoIcons.star,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: favorites.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final favorite = favorites[index];
                        final account = widget.services.vault
                            .profiles(favorite.session.platform)
                            .where((a) => a.id == favorite.session.accountId)
                            .firstOrNull;
                        return Material(
                          color: Theme.of(context).colorScheme.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: border(context)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            key: ValueKey('favorite-${favorite.id}'),
                            leading: favorite.isShareLink
                                ? const Icon(
                                    CupertinoIcons.link,
                                    color: Color(0xffe6a23c),
                                  )
                                : FileGlyph(
                                    favorite.file.name,
                                    directory: favorite.file.isDirectory,
                                  ),
                            title: Text(
                              favorite.file.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${favorite.session.platform.shortName}${account == null ? '' : ' · ${account.name}'}\n${favorite.location}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            isThreeLine: true,
                            onTap: () => _open(favorite),
                            trailing: IconButton(
                              tooltip: '取消收藏',
                              icon: const Icon(
                                CupertinoIcons.star_fill,
                                color: Color(0xffe6a23c),
                                size: 21,
                              ),
                              onPressed: () async {
                                await busy(
                                  context,
                                  () => widget.services.favorites.remove(
                                    favorite.id,
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}

class CloudFavoritesSummary extends StatefulWidget {
  const CloudFavoritesSummary(
    this.services, {
    super.key,
    required this.desktop,
    this.enabled = true,
  });
  final AppServices services;
  final bool desktop, enabled;

  @override
  State<CloudFavoritesSummary> createState() => _CloudFavoritesSummaryState();
}

class _CloudFavoritesSummaryState extends State<CloudFavoritesSummary> {
  bool _opening = false;

  Future<void> _open(CloudFavorite favorite) async {
    if (_opening || !widget.enabled) return;
    setState(() => _opening = true);
    try {
      await openCloudFavorite(context, widget.services, favorite);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.services.store,
    builder: (context, _) {
      final favorites = widget.services.favorites.all;
      final enabled = widget.enabled && !_opening;
      final accent = Theme.of(context).brightness == Brightness.dark
          ? const Color(0xffffca70)
          : const Color(0xffa66b0a);
      return Padding(
        padding: EdgeInsets.all(widget.desktop ? 20 : 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              key: const Key('parse-favorites'),
              borderRadius: BorderRadius.circular(8),
              onTap: enabled
                  ? () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CloudFavoritesPage(widget.services),
                      ),
                    )
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.star_fill, size: 18, color: accent),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '网盘收藏',
                        style: TextStyle(
                          fontSize: widget.desktop ? 14 : 18,
                          fontWeight: widget.desktop
                              ? FontWeight.w600
                              : FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      favorites.isEmpty ? '全部' : '全部 ${favorites.length}',
                      style: TextStyle(fontSize: 12, color: accent),
                    ),
                    const SizedBox(width: 4),
                    Icon(CupertinoIcons.chevron_right, size: 14, color: accent),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (favorites.isEmpty)
              Text(
                '收藏分享链接、文件或文件夹，下次从这里直达',
                style: TextStyle(fontSize: 13, color: secondary(context)),
              )
            else
              for (final favorite in favorites.take(3))
                InkWell(
                  key: ValueKey('home-favorite-${favorite.id}'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: enabled ? () => _open(favorite) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: .09),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Icon(
                            favorite.isShareLink
                                ? CupertinoIcons.link
                                : favorite.file.isDirectory
                                ? CupertinoIcons.folder
                                : CupertinoIcons.doc,
                            color: accent,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                favorite.file.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _location(favorite),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: secondary(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          CupertinoIcons.arrow_up_right,
                          size: 15,
                          color: accent,
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      );
    },
  );

  String _location(CloudFavorite favorite) {
    final account = widget.services.vault
        .profiles(favorite.session.platform)
        .where((a) => a.id == favorite.session.accountId)
        .firstOrNull;
    return '${favorite.session.platform.shortName}'
        '${account == null ? '' : ' · ${account.name}'}'
        ' · ${favorite.isShareLink
            ? '分享链接 · ${favorite.session.sourceLink?.url ?? ''}'
            : favorite.file.isDirectory
            ? '直达文件夹'
            : '打开所在文件夹'}';
  }
}
