import 'package:fl_clash/models/app_usage.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> day(
  String date,
  String app,
  int upload,
  int download, {
  String? path,
  String? profileId,
  String? profileName,
  int? proxyUpload,
  int? proxyDownload,
  bool classified = true,
}) => {
  'date': date,
  'apps': {
    app: {
      'app': app,
      'process': app,
      'processPath': path ?? '',
      'upload': upload,
      'download': download,
      'profileId': ?profileId,
      'profileName': ?profileName,
      if (classified) 'proxyUpload': proxyUpload ?? upload,
      if (classified) 'proxyDownload': proxyDownload ?? download,
    },
  },
};

void main() {
  test('merges daily usage by application and sorts by total', () {
    final report = AppUsageReport.fromJson([
      day('2026-11-18', 'browser', 10, 100),
      day('2026-11-19', 'browser', 20, 200),
      day('2026-11-19', 'download', 1, 500),
      day('2026-11-19', '', 0, 7),
    ]);
    expect(report.apps.map((app) => app.app), ['download', 'browser', '']);
    expect(report.apps[1].upload, 30);
    expect(report.apps[1].download, 300);
    expect(report.apps[1].days.length, 2);
    expect(report.upload, 31);
    expect(report.download, 807);
    expect(report.total, 838);
  });

  test('keeps same-named applications at different paths distinct', () {
    final report = AppUsageReport.fromJson([
      day('2026-11-19', '/one/app', 1, 2),
      day('2026-11-19', '/two/app', 3, 4),
    ]);
    expect(report.apps.length, 2);
  });

  test('falls back to a filename when only the process path is known', () {
    final app = AppUsage(
      app: 'key',
      process: '',
      processPath: r'C:\Apps\browser.exe',
      days: {},
    );
    expect(app.name, 'browser.exe');
  });

  test('empty history has zero totals', () {
    final report = AppUsageReport.fromJson([]);
    expect(report.apps, isEmpty);
    expect(report.total, 0);
  });

  test('profile filters isolate one app and preserve the combined total', () {
    final report = AppUsageReport.fromJson([
      day('2026-11-18', 'browser', 10, 20, profileId: 'a', profileName: 'Work'),
      day('2026-11-19', 'browser', 30, 40, profileId: 'b', profileName: 'Home'),
      day('2026-11-19', 'browser', 5, 10, profileId: 'a', profileName: 'Work'),
    ]);
    expect(report.total, 115);
    expect(report.apps.single.total, 115);
    expect(report.profiles.map((profile) => profile.id), ['b', 'a']);
    expect(report.forProfile('a').total, 45);
    expect(report.forProfile('a').apps.single.days.length, 2);
    expect(report.forProfile('b').total, 70);
    expect(report.forProfile('b').apps.single.days.keys, ['2026-11-19']);
    expect(report.forProfile(null).total, 115);
    expect(report.forProfile('missing').total, 0);
  });

  test('profile identity survives renames and does not merge equal names', () {
    final report = AppUsageReport.fromJson([
      day('2026-11-18', 'browser', 0, 10, profileId: 'a', profileName: 'Old'),
      day('2026-11-19', 'browser', 0, 20, profileId: 'a', profileName: 'Same'),
      day('2026-11-19', 'browser', 0, 40, profileId: 'b', profileName: 'Same'),
    ]);
    expect(report.profiles.length, 2);
    expect(report.profile('a')?.name, 'Same');
    expect(report.forProfile('a').total, 30);
    expect(report.forProfile('b').total, 40);
  });

  test('legacy records remain in an unassigned profile', () {
    final report = AppUsageReport.fromJson([
      day('2026-11-18', 'browser', 0, 10, classified: false),
      day(
        '2026-11-19',
        'browser',
        0,
        20,
        profileId: 'a',
        profileName: 'Current',
      ),
    ]);
    expect(report.forProfile('').total, 0);
    expect(report.forProfile('a').total, 20);
    expect(report.profile('')?.name, '');
    expect(report.total, 30);
  });

  test(
    'profiles count measured proxy bytes while forwarding preserves all traffic',
    () {
      final report = AppUsageReport.fromJson([
        day('2026-11-18', 'old', 1000, 0, profileId: 'p', classified: false),
        day(
          '2026-11-19',
          'browser',
          110,
          220,
          profileId: 'p',
          proxyUpload: 10,
          proxyDownload: 20,
        ),
        day(
          '2026-11-19',
          'direct',
          500,
          0,
          profileId: 'p',
          proxyUpload: 0,
          proxyDownload: 0,
        ),
        day('2026-11-19', 'other', 1, 2, profileId: 'q'),
      ]);
      expect(report.total, 1833);
      expect(
        report.apps.map((app) => app.app),
        containsAll(['old', 'browser', 'direct', 'other']),
      );
      final proxy = report.forProfile('p');
      expect(proxy.total, 30);
      expect(proxy.upload, 10);
      expect(proxy.download, 20);
      expect(proxy.apps.single.app, 'browser');
      expect(proxy.days, {'2026-11-19': (upload: 10, download: 20)});
      expect(report.forProfile('q').total, 3);
    },
  );

  test('presets include today and cross month boundaries', () {
    final range = AppUsageRange.lastDays(7, DateTime(2026, 3, 2, 23));
    expect(appUsageDate(range.from), '2026-02-24');
    expect(appUsageDate(range.to), '2026-03-02');
    expect(
      appUsageDate(AppUsageRange.lastDays(1, DateTime(2026, 3, 2)).from),
      '2026-03-02',
    );
  });

  test('custom dates reject normalized invalid dates and reversed ranges', () {
    expect(AppUsageRange.tryParse('2026-02-30', '2026-03-02'), isNull);
    expect(AppUsageRange.tryParse('2026-03-02', '2026-03-01'), isNull);
    expect(AppUsageRange.tryParse('../path', '2026-03-02'), isNull);
    expect(AppUsageRange.tryParse('2024-02-29', '2024-02-29'), isNotNull);
  });
}
