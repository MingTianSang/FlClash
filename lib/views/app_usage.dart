import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/models/app_usage.dart';
import 'package:fl_clash/models/common.dart' show TrafficShowExt;
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppUsageView extends ConsumerStatefulWidget {
  final String? profileId;
  final String? profileName;
  final int initialPeriod;
  final AppUsageRange? initialRange;

  const AppUsageView({
    super.key,
    this.profileId,
    this.profileName,
    this.initialPeriod = 30,
    this.initialRange,
  });

  @override
  ConsumerState<AppUsageView> createState() => _AppUsageViewState();
}

class _AppUsageViewState extends ConsumerState<AppUsageView>
    with WidgetsBindingObserver, ActivePollingMixin<AppUsageView> {
  AppUsageReport? _report;
  AppUsageRange? _customRange;
  int _period = 30;
  int _revision = 0;
  String _query = '';
  bool _loading = false;
  bool _failed = false;
  bool _byProfile = false;

  bool get _isProfile => widget.profileId != null;
  bool get _showProfiles => !_isProfile && _byProfile;

  @override
  Duration get pollInterval => const Duration(seconds: 5);

  @override
  bool get pollOnStart => false;

  AppUsageRange get _range =>
      _customRange ?? AppUsageRange.lastDays(_period, DateTime.now());

  @override
  void initState() {
    super.initState();
    _period = widget.initialPeriod;
    _customRange = widget.initialRange;
    unawaited(_load());
  }

  @override
  Future<void> poll(PollGuard isCurrent) => _load(isCurrent: isCurrent);

  Future<void> _load({PollGuard? isCurrent}) async {
    final revision = ++_revision;
    setState(() => _loading = true);
    try {
      final report = await ref.read(coreHandlerProvider).getAppUsage(_range);
      if (!mounted || revision != _revision || !(isCurrent?.call() ?? true)) {
        return;
      }
      setState(() {
        _report = report;
        _failed = false;
      });
    } catch (_) {
      if (mounted && revision == _revision && (isCurrent?.call() ?? true)) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _selectPeriod(int period) async {
    AppUsageRange? custom;
    if (period == 0) {
      custom = await showFormSheet<AppUsageRange>(
        context: context,
        builder: (_) => _AppUsageRangeForm(range: _range),
      );
      if (!mounted || custom == null) return;
    }
    setState(() {
      _period = period;
      _customRange = custom;
      _report = null;
      _failed = false;
    });
    await _load();
  }

  String _profileLabel(AppUsageProfile profile) => profile.id.isEmpty
      ? context.appLocalizations.appUsageUnknownProfile
      : profile.name.isEmpty
      ? '#${profile.id}'
      : profile.name;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final profile = _report?.profile(widget.profileId);
    final profileName = profile == null
        ? widget.profileName ?? '#${widget.profileId}'
        : _profileLabel(profile);
    return Scaffold(
      title: _isProfile ? profileName : l10n.usage,
      searchState: AppBarSearchState(
        onSearch: (query) =>
            setState(() => _query = query.trim().toLowerCase()),
      ),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.sync,
          tooltip: l10n.update,
          isLoading: _loading,
          onPressed: _loading ? null : _load,
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
            ).copyWith(top: context.sectionsTopPadding, bottom: 16),
            child: SegmentedControl<int>(
              segments: [
                (1, l10n.appUsageToday),
                (7, l10n.appUsageWeek),
                (30, l10n.appUsageMonth),
                (0, l10n.custom),
              ],
              value: _period,
              onChanged: _selectPeriod,
            ),
          ),
          if (!_isProfile)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SegmentedControl<bool>(
                segments: [
                  (false, l10n.appUsage),
                  (true, l10n.appUsageProfiles),
                ],
                value: _byProfile,
                onChanged: (value) => setState(() => _byProfile = value),
              ),
            ),
          Expanded(
            child: NullStatusSwitcher(
              isLoading: _report == null && !_failed,
              loadingStatus: const NullStatus(
                illustration: NullStatusIllustration.data,
              ),
              child: _failed
                  ? NullStatus(
                      illustration: NullStatusIllustration.apps,
                      label: l10n.appUsageLoadFailed,
                      action: TextButton(
                        onPressed: _load,
                        child: Text(l10n.retry),
                      ),
                    )
                  : _buildReport(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReport(BuildContext context) {
    final report = _report;
    if (report == null) return const SizedBox();
    final l10n = context.appLocalizations;
    final range = _range;
    final selected = report.forProfile(widget.profileId);
    final apps = selected.apps
        .where(
          (app) =>
              _query.isEmpty ||
              '${app.name} ${app.processPath}'.toLowerCase().contains(_query),
        )
        .toList();
    final filtered = _query.isEmpty ? selected : AppUsageReport(apps);
    final profiles = report.profiles
        .where(
          (profile) =>
              _query.isEmpty ||
              '${_profileLabel(profile)} ${profile.id}'.toLowerCase().contains(
                _query,
              ),
        )
        .toList();
    final upload = _showProfiles
        ? profiles.fold(0, (sum, profile) => sum + profile.usage.upload)
        : filtered.upload;
    final download = _showProfiles
        ? profiles.fold(0, (sum, profile) => sum + profile.usage.download)
        : filtered.download;
    final total = upload + download;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${appUsageDate(range.from)} – ${appUsageDate(range.to)}',
                  style: AppTextStyle.footnote.of(context),
                ),
                const SizedBox(height: 12),
                _UsageTotals(upload: upload, download: download),
                const SizedBox(height: 12),
                Text(
                  _showProfiles || _isProfile
                      ? l10n.appUsageProfileHint
                      : l10n.appUsageHint,
                  style: AppTextStyle.footnote.of(context),
                ),
                const SizedBox(height: 16),
                if (_showProfiles ? profiles.isEmpty : apps.isEmpty)
                  Text(
                    l10n.appUsageEmpty,
                    style: AppTextStyle.body.of(context),
                  ),
              ],
            ),
          ),
        ),
        if (_isProfile && filtered.days.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Text(
                l10n.appUsageDaily,
                style: AppTextStyle.headline.of(context),
              ),
            ),
          ),
          _UsageDays(days: filtered.days),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Text(l10n.app, style: AppTextStyle.headline.of(context)),
            ),
          ),
        ],
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + context.bottomInset),
          sliver: SliverPrismList(
            itemCount: _showProfiles ? profiles.length : apps.length,
            estimatedItemExtent: 138,
            gap: 8,
            itemBuilder: (context, index) {
              if (_showProfiles) {
                final profile = profiles[index];
                final usage = profile.usage;
                return Card(
                  key: ValueKey(profile.id),
                  onPressed: () => BaseNavigator.push(
                    context,
                    AppUsageView(
                      profileId: profile.id,
                      profileName: _profileLabel(profile),
                      initialPeriod: _period,
                      initialRange: _customRange,
                    ),
                  ),
                  child: ListRow(
                    title: Text(
                      _profileLabel(profile),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${profile.id.isEmpty ? '' : '#${profile.id}\n'}'
                      '${l10n.upload} ${usage.upload.traffic.show}   '
                      '${l10n.download} ${usage.download.traffic.show}',
                    ),
                    trailing: Text(usage.total.traffic.show),
                  ),
                );
              }
              final app = apps[index];
              return _AppUsageCard(
                key: ValueKey(app.app),
                app: app,
                share: total == 0 ? 0 : app.total / total,
                onPressed: () => BaseNavigator.push(
                  context,
                  _AppUsageDetail(
                    app: app,
                    profileName: _isProfile ? widget.profileName : null,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _UsageTotals extends StatelessWidget {
  final int upload;
  final int download;

  const _UsageTotals({required this.upload, required this.download});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return Card(
      padding: const EdgeInsets.all(16),
      child: Row(
        spacing: 12,
        children: [
          for (final figure in [
            (l10n.total, upload + download),
            (l10n.upload, upload),
            (l10n.download, download),
          ])
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(figure.$1, style: AppTextStyle.caption1.of(context)),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      figure.$2.traffic.show,
                      style: AppTextStyle.title2.of(context).toTabular,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AppUsageCard extends StatelessWidget {
  final AppUsage app;
  final double share;
  final VoidCallback onPressed;

  const _AppUsageCard({
    super.key,
    required this.app,
    required this.share,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return Card(
      onPressed: onPressed,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            spacing: 12,
            children: [
              const GlyphIcon(AppGlyphs.appsList),
              Expanded(
                child: Text(
                  app.name.isEmpty ? l10n.appUsageUnknown : app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.headline.of(context),
                ),
              ),
              Text(
                app.total.traffic.show,
                style: AppTextStyle.headline.of(context).toTabular,
              ),
            ],
          ),
          if (app.processPath.isNotEmpty)
            Text(
              app.processPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption1.of(context),
            ),
          SizedBox(
            height: 4,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: context.colorScheme.surfaceContainerHighest,
                shape: AppShape.full,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FractionallySizedBox(
                  widthFactor: share,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: context.colorScheme.primary,
                      shape: AppShape.full,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text(
                '${l10n.upload} ${app.upload.traffic.show}',
                style: AppTextStyle.footnote.of(context),
              ),
              Text(
                '${l10n.download} ${app.download.traffic.show}',
                style: AppTextStyle.footnote.of(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppUsageDetail extends StatelessWidget {
  final AppUsage app;
  final String? profileName;

  const _AppUsageDetail({required this.app, this.profileName});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return Scaffold(
      title: app.name.isEmpty ? l10n.appUsageUnknown : app.name,
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(
              16,
            ).copyWith(top: context.sectionsTopPadding),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  if (profileName != null)
                    Text(
                      '${l10n.profile}: $profileName',
                      style: AppTextStyle.footnote.of(context),
                    ),
                  if (app.processPath.isNotEmpty)
                    SelectableText(app.processPath),
                  _UsageTotals(upload: app.upload, download: app.download),
                  Text(
                    l10n.appUsageDaily,
                    style: AppTextStyle.headline.of(context),
                  ),
                ],
              ),
            ),
          ),
          _UsageDays(days: app.days, bottomInset: context.bottomInset),
        ],
      ),
    );
  }
}

class _UsageDays extends StatelessWidget {
  final Map<String, AppUsageTraffic> days;
  final double bottomInset;

  const _UsageDays({required this.days, this.bottomInset = 0});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final entries = days.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
      sliver: SliverPrismList(
        itemCount: entries.length,
        estimatedItemExtent: 80,
        gap: 8,
        itemBuilder: (context, index) {
          final day = entries[index];
          return Card(
            child: ListRow(
              title: Text(day.key),
              subtitle: Text(
                '${l10n.upload} ${day.value.upload.traffic.show}   '
                '${l10n.download} ${day.value.download.traffic.show}',
              ),
              trailing: Text(
                (day.value.upload + day.value.download).traffic.show,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AppUsageRangeForm extends StatefulWidget {
  final AppUsageRange range;

  const _AppUsageRangeForm({required this.range});

  @override
  State<_AppUsageRangeForm> createState() => _AppUsageRangeFormState();
}

class _AppUsageRangeFormState extends State<_AppUsageRangeForm> {
  late final TextEditingController _from;
  late final TextEditingController _to;
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _from = TextEditingController(text: appUsageDate(widget.range.from));
    _to = TextEditingController(text: appUsageDate(widget.range.to));
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _save() {
    final range = AppUsageRange.tryParse(_from.text.trim(), _to.text.trim());
    if (range == null) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(range);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return FormPage(
      title: l10n.appUsageCustomRange,
      error: _invalid ? l10n.appUsageInvalidRange : null,
      onSave: _save,
      children: [
        generateSection(
          items: [
            FormRow(
              title: l10n.appUsageFrom,
              trailing: FormRowTextField(
                controller: _from,
                hintText: 'YYYY-MM-DD',
                autocorrect: false,
              ),
            ),
            FormRow(
              title: l10n.appUsageTo,
              trailing: FormRowTextField(
                controller: _to,
                hintText: 'YYYY-MM-DD',
                autocorrect: false,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
