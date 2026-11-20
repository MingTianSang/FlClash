import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/app_usage.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/app_usage.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_desktop_window.dart';
import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _UsageCore extends Mock implements CoreHandlerInterface {
  final ranges = <AppUsageRange>[];
  Future<AppUsageReport> Function(AppUsageRange)? load;

  @override
  Future<AppUsageReport> getAppUsage(AppUsageRange range) async {
    ranges.add(range);
    return load?.call(range) ?? AppUsageReport([]);
  }
}

AppUsageReport _report({String name = 'browser.exe', int count = 1}) {
  return AppUsageReport([
    for (var i = 0; i < count; i++)
      AppUsage(
        app: '$i',
        process: count == 1 ? name : 'app-$i.exe',
        processPath: 'C:/Applications/$i/$name',
        days: const {
          '2026-11-18': (upload: 1024, download: 2048),
          '2026-11-19': (upload: 2048, download: 4096),
        },
      ),
  ]);
}

AppUsageReport _profileReport() => AppUsageReport.fromJson([
  for (final row in [
    ('office', 'Office', 'work.exe', 1024),
    ('home', 'Home', 'home.exe', 2048),
    ('office', 'Office', 'direct.exe', 8192),
    ('', '', 'legacy.exe', 4096),
  ])
    {
      'date': row.$1 == 'office' ? '2026-11-18' : '2026-11-19',
      'apps': {
        row.$3: {
          'app': row.$3,
          'process': row.$3,
          'processPath': '',
          'profileId': row.$1,
          'profileName': row.$2,
          'upload': 0,
          'download': row.$4,
          if (row.$1.isNotEmpty) 'proxyUpload': 0,
          if (row.$1.isNotEmpty)
            'proxyDownload': row.$3 == 'direct.exe' ? 0 : row.$4,
        },
      },
    },
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _UsageCore core;
  late ProviderContainer container;

  setUp(() {
    FakeDesktopWindow().install();
    core = _UsageCore();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    globalState.container = container;
  });

  tearDown(() => container.dispose());

  Future<void> pumpUsage(
    WidgetTester tester, {
    Size size = const Size(1100, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    container.read(viewSizeProvider.notifier).update((_) => size);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(locale: Locale('en'), child: AppUsageView()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('shows application totals and opens daily history', (
    tester,
  ) async {
    core.load = (_) async => _report();
    await pumpUsage(tester);
    expect(find.text('browser.exe'), findsOneWidget);
    await tester.tap(find.text('browser.exe'));
    await tester.pumpAndSettle();
    expect(find.text('Daily usage'), findsOneWidget);
    expect(find.text('2026-11-18'), findsOneWidget);
    expect(find.text('2026-11-19'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a period queries the inclusive calendar range', (
    tester,
  ) async {
    core.load = (_) async => _report();
    await pumpUsage(tester);
    await tester.tap(find.text('7 days'));
    await tester.pump();
    final expected = AppUsageRange.lastDays(7, DateTime.now());
    expect(appUsageDate(core.ranges.last.from), appUsageDate(expected.from));
    expect(appUsageDate(core.ranges.last.to), appUsageDate(expected.to));
  });

  testWidgets('validates and applies a custom date range', (tester) async {
    core.load = (_) async => _report();
    await pumpUsage(tester);
    await tester.tap(find.text('Custom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.first, '2026-02-30');
    await tester.enterText(fields.last, '2026-03-05');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Enter valid dates'), findsOneWidget);
    await tester.enterText(fields.first, '2026-03-01');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(appUsageDate(core.ranges.last.from), '2026-03-01');
    expect(appUsageDate(core.ranges.last.to), '2026-03-05');
  });

  testWidgets('shows an empty state and recovers from a read failure', (
    tester,
  ) async {
    core.load = (_) => Future.error(StateError('unavailable'));
    await pumpUsage(tester);
    expect(find.text('Unable to load usage history.'), findsOneWidget);
    core.load = (_) async => AppUsageReport([]);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No usage recorded for this period.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an old query cannot replace a more recent period', (
    tester,
  ) async {
    final old = Completer<AppUsageReport>();
    core.load = (_) => core.ranges.length == 1
        ? old.future
        : Future.value(_report(name: 'new.exe'));
    await pumpUsage(tester);
    await tester.tap(find.text('7 days'));
    await tester.pump();
    old.complete(_report(name: 'old.exe'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('new.exe'), findsOneWidget);
    expect(find.text('old.exe'), findsNothing);
  });

  testWidgets('visible-page refresh pauses while the app is hidden', (
    tester,
  ) async {
    core.load = (_) async => _report();
    await pumpUsage(tester);
    final count = core.ranges.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 6));
    expect(core.ranges.length, count);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 6));
    expect(core.ranges.length, greaterThan(count));
  });

  testWidgets('large histories build only visible application rows', (
    tester,
  ) async {
    core.load = (_) async => _report(count: 10000);
    await pumpUsage(tester);
    expect(find.byType(Card).evaluate().length, lessThan(40));
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.position.jumpTo(600000);
    await tester.pump();
    expect(find.byType(Card).evaluate().length, lessThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a phone viewport', (tester) async {
    core.load = (_) async => _report();
    await pumpUsage(tester, size: const Size(390, 844));
    expect(find.text('browser.exe'), findsOneWidget);
    await tester.tap(find.text('browser.exe'));
    await tester.pumpAndSettle();
    final date = tester.getRect(find.text('2026-11-19'));
    expect(date.left, greaterThanOrEqualTo(0));
    expect(date.right, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a profile opens independent proxy statistics and keeps the root on profiles',
    (tester) async {
      core.load = (_) async => _profileReport();
      await pumpUsage(tester);
      await tester.tap(find.text('Profile usage'));
      await tester.pumpAndSettle();
      expect(find.text('Office'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Unassigned profile'), findsOneWidget);
      expect(find.text('work.exe'), findsNothing);
      await tester.tap(find.text('Office'));
      await tester.pumpAndSettle();
      expect(find.text('Traffic forwarding'), findsNothing);
      expect(find.text('Profile usage'), findsNothing);
      expect(find.text('Daily usage'), findsOneWidget);
      expect(find.text('work.exe'), findsOneWidget);
      expect(find.text('home.exe'), findsNothing);
      expect(find.text('legacy.exe'), findsNothing);
      expect(find.text('direct.exe'), findsNothing);
      await tester.tap(find.text('work.exe'));
      await tester.pumpAndSettle();
      expect(find.text('Profile: Office'), findsOneWidget);
      expect(find.text('2026-11-18'), findsOneWidget);
      expect(find.text('2026-11-19'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedControl<bool>>(find.byType(SegmentedControl<bool>))
            .value,
        isTrue,
      );
      await tester.tap(find.text('Traffic forwarding'));
      await tester.pumpAndSettle();
      expect(find.text('direct.exe'), findsOneWidget);
      expect(find.text('legacy.exe'), findsOneWidget);
      expect(find.text('Office'), findsNothing);
      expect(find.text('All profiles'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a profile has its own date range on a phone and forwarding has no profile picker',
    (tester) async {
      core.load = (_) async => _profileReport();
      await pumpUsage(tester, size: const Size(390, 844));
      expect(find.text('Usage'), findsOneWidget);
      expect(find.text('All profiles'), findsNothing);
      expect(find.text('Office'), findsNothing);
      await tester.tap(find.text('7 days'));
      await tester.pumpAndSettle();
      final rootRange = appUsageDate(core.ranges.last.from);
      await tester.tap(find.text('Profile usage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Office'));
      await tester.pumpAndSettle();
      expect(appUsageDate(core.ranges.last.from), rootRange);
      expect(find.text('Daily usage'), findsOneWidget);
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      expect(appUsageDate(core.ranges.last.from), appUsageDate(DateTime.now()));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedControl<int>>(find.byType(SegmentedControl<int>))
            .value,
        7,
      );
      expect(
        tester
            .widget<SegmentedControl<bool>>(find.byType(SegmentedControl<bool>))
            .value,
        isTrue,
      );
      await tester.tap(find.text('Traffic forwarding'));
      await tester.pumpAndSettle();
      expect(find.text('work.exe'), findsOneWidget);
      expect(find.text('home.exe'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
