String appUsageDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

class AppUsageRange {
  final DateTime from;
  final DateTime to;

  const AppUsageRange(this.from, this.to);

  factory AppUsageRange.lastDays(int days, DateTime now) {
    return AppUsageRange(
      DateTime(now.year, now.month, now.day - days + 1),
      DateTime(now.year, now.month, now.day),
    );
  }

  static AppUsageRange? tryParse(String from, String to) {
    final start = DateTime.tryParse(from);
    final end = DateTime.tryParse(to);
    if (start == null ||
        end == null ||
        appUsageDate(start) != from ||
        appUsageDate(end) != to ||
        end.isBefore(start)) {
      return null;
    }
    return AppUsageRange(start, end);
  }
}

typedef AppUsageTraffic = ({int upload, int download});

class AppUsage {
  final String app;
  final String process;
  final String processPath;
  final Map<String, AppUsageTraffic> days;
  final int upload;
  final int download;

  AppUsage({
    required this.app,
    required this.process,
    required this.processPath,
    required Map<String, AppUsageTraffic> days,
  }) : days = Map.unmodifiable(days),
       upload = days.values.fold(0, (sum, day) => sum + day.upload),
       download = days.values.fold(0, (sum, day) => sum + day.download);

  String get name => process.isNotEmpty
      ? process
      : processPath.replaceAll('\\', '/').split('/').last;

  int get total => upload + download;
}

class AppUsageReport {
  final List<AppUsage> apps;
  final List<AppUsageProfile> profiles;
  final int upload;
  final int download;
  final Map<String, AppUsageTraffic> days;

  AppUsageReport(
    List<AppUsage> apps, {
    List<AppUsageProfile> profiles = const [],
  }) : apps = List.unmodifiable(apps),
       profiles = List.unmodifiable(profiles),
       days = Map.unmodifiable(_mergeUsageDays(apps)),
       upload = apps.fold(0, (sum, app) => sum + app.upload),
       download = apps.fold(0, (sum, app) => sum + app.download);

  factory AppUsageReport.fromJson(Object? data) {
    final samples = <_AppUsageSample>[
      for (final day in data as List)
        for (final value in (day['apps'] as Map).values)
          (
            date: day['date'] as String,
            app: value['app'] as String,
            process: value['process'] as String,
            path: value['processPath'] as String,
            profileId: value['profileId'] as String? ?? '',
            profileName: value['profileName'] as String? ?? '',
            upload: (value['upload'] as num).toInt(),
            download: (value['download'] as num).toInt(),
            proxyUpload: (value['proxyUpload'] as num?)?.toInt() ?? 0,
            proxyDownload: (value['proxyDownload'] as num?)?.toInt() ?? 0,
          ),
    ];
    final grouped = <String, List<_AppUsageSample>>{};
    for (final sample in samples) {
      grouped.putIfAbsent(sample.profileId, () => []).add(sample);
    }
    final profiles =
        <AppUsageProfile>[
          for (final entry in grouped.entries)
            AppUsageProfile(
              id: entry.key,
              name: entry.value.reversed
                  .map((sample) => sample.profileName)
                  .firstWhere((name) => name.isNotEmpty, orElse: () => ''),
              usage: AppUsageReport(
                _mergeAppUsage(entry.value, onlyProxy: true),
              ),
            ),
        ]..sort((a, b) {
          final total = b.usage.total.compareTo(a.usage.total);
          return total == 0 ? a.id.compareTo(b.id) : total;
        });
    return AppUsageReport(_mergeAppUsage(samples), profiles: profiles);
  }

  AppUsageProfile? profile(String? id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  AppUsageReport forProfile(String? id) =>
      id == null ? this : profile(id)?.usage ?? AppUsageReport([]);

  int get total => upload + download;
}

class AppUsageProfile {
  final String id;
  final String name;
  final AppUsageReport usage;

  const AppUsageProfile({
    required this.id,
    required this.name,
    required this.usage,
  });
}

typedef _AppUsageSample = ({
  String date,
  String app,
  String process,
  String path,
  String profileId,
  String profileName,
  int upload,
  int download,
  int proxyUpload,
  int proxyDownload,
});

Map<String, AppUsageTraffic> _mergeUsageDays(List<AppUsage> apps) {
  final days = <String, AppUsageTraffic>{};
  for (final app in apps) {
    for (final day in app.days.entries) {
      final previous = days[day.key];
      days[day.key] = (
        upload: (previous?.upload ?? 0) + day.value.upload,
        download: (previous?.download ?? 0) + day.value.download,
      );
    }
  }
  return days;
}

List<AppUsage> _mergeAppUsage(
  List<_AppUsageSample> samples, {
  bool onlyProxy = false,
}) {
  final apps =
      <
        String,
        ({String process, String path, Map<String, AppUsageTraffic> days})
      >{};
  for (final sample in samples) {
    final upload = onlyProxy ? sample.proxyUpload : sample.upload;
    final download = onlyProxy ? sample.proxyDownload : sample.download;
    if (upload == 0 && download == 0) continue;
    final key = sample.app;
    final app = apps.putIfAbsent(
      key,
      () => (
        process: sample.process,
        path: sample.path,
        days: <String, AppUsageTraffic>{},
      ),
    );
    final previous = app.days[sample.date];
    app.days[sample.date] = (
      upload: (previous?.upload ?? 0) + upload,
      download: (previous?.download ?? 0) + download,
    );
  }
  return apps.entries
      .map(
        (entry) => AppUsage(
          app: entry.key,
          process: entry.value.process,
          processPath: entry.value.path,
          days: entry.value.days,
        ),
      )
      .where((app) => app.total > 0)
      .toList()
    ..sort((a, b) {
      final total = b.total.compareTo(a.total);
      return total == 0 ? a.app.compareTo(b.app) : total;
    });
}
