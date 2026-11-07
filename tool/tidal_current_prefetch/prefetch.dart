// 조류(수치조류도 예측) 미리 받기 — 인천 바다의 예측값을 정적 파일로 만든다.
//
// 사용:
//   KHOA_KEY=<국립해양조사원 해양빅데이터 인증키> dart tool/tidal_current_prefetch/prefetch.dart --out site
//
// 옵션(모두 선택):
//   --out <폴더>        결과를 쓰는 폴더(기본 site). index.json·tc/ 가 여기 생긴다 — 이 폴더를 웹에 올린다.
//   --max-calls <수>    이번 실행에서 서버를 부르는 최대 횟수(기본 9000). 넘으면 거기서 멈추고 받은 것까지만 올린다.
//   --reserve <수>      하루 한도(20,000) 중 앱 직접 호출용으로 남겨 둘 횟수(기본 3000). 남은 횟수가 이보다 적으면 멈춘다.
//   --concurrency <수>  동시에 부르는 횟수(기본 6).
//   --hours <수>        지금부터 몇 시간 앞까지 만들지(기본 27).
//
// 이미 만든 장면은 건너뛰므로(폴더를 보관해 두면) 다시 실행해도 새 장면만 받는다. 인증키는 출력·파일에 남기지 않는다.
// 서버는 요청 하나에 약 100점만 돌려주므로 0.1° 타일(312칸)로 나눠 부르고, 바다가 아닌 타일은 처음 한 번만 확인해
// 이후엔 건너뛴다(_state.json). 0.25°·0.5° 타일은 0.1° 점들에서 솎아 만든다.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'prefetch_core.dart';

class _Budget {
  int calls = 0;
  final int maxCalls;
  final int reserve;
  int? remaining; // 서버가 알려 준 남은 하루 횟수

  _Budget(this.maxCalls, this.reserve);

  bool get exhausted =>
      calls >= maxCalls || (remaining != null && remaining! < reserve);
}

late String _key;
final HttpClient _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15);

Future<Map<String, dynamic>> _fetch(
  PrefetchTile t,
  DateTime time,
  _Budget b,
) async {
  b.calls++;
  String two(int v) => v.toString().padLeft(2, '0');
  final q = [
    'ServiceKey=${Uri.encodeQueryComponent(_key)}',
    'Date=${time.year}${two(time.month)}${two(time.day)}',
    'Hour=${two(time.hour)}',
    'Minute=${two(time.minute)}',
    'MaxX=${t.maxX}',
    'MinX=${t.minX}',
    'MaxY=${t.maxY}',
    'MinY=${t.minY}',
    'ResultType=json',
  ].join('&');
  // KHOA_ENDPOINT은 시험 전용(가짜 서버) — 실제 실행에서는 설정하지 않는다
  final endpoint =
      Platform.environment['KHOA_ENDPOINT'] ??
      'https://khoa.go.kr/oceandata/api/tidalCurrentArea/search.do';
  final uri = Uri.parse('$endpoint?$q');
  final req = await _http.getUrl(uri).timeout(const Duration(seconds: 20));
  final res = await req.close().timeout(const Duration(seconds: 40));
  final body = await res
      .transform(utf8.decoder)
      .join()
      .timeout(const Duration(seconds: 40));
  if (res.statusCode != 200) {
    throw HttpException('HTTP ${res.statusCode}');
  }
  final json = jsonDecode(body);
  if (json is! Map<String, dynamic>) throw const FormatException('응답 형식 오류');
  // 남은 하루 횟수 — "19998/20000"
  final cnt = (json['result'] is Map)
      ? ((json['result'] as Map)['meta'] is Map
            ? ((json['result'] as Map)['meta'] as Map)['obs_last_req_cnt']
            : null)
      : null;
  if (cnt is String) {
    final left = int.tryParse(cnt.split('/').first.trim());
    if (left != null) b.remaining = left;
  }
  return json;
}

/// 한 타일을 (실패하면 두 번 더) 받는다. 예외는 호출한 쪽이 처리한다. 키가 든 주소는 오류에 싣지 않는다.
Future<List<PrefetchPoint>> _fetchTile(
  PrefetchTile t,
  DateTime time,
  _Budget b,
) async {
  Object? last;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (b.exhausted) throw StateError('호출 한도에 닿았다');
    try {
      return parseApiBody(await _fetch(t, time, b));
    } on StateError {
      rethrow;
    } catch (e) {
      last = e.runtimeType;
      await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
    }
  }
  throw StateError('타일 ${t.shortId} 받기 실패(${last ?? '?'})');
}

/// [jobs]를 [concurrency]개씩 동시에 돌린다. 하나라도 실패하면 나머지는 시작하지 않고 그 예외를 던진다.
Future<void> _pool<T>(
  List<T> jobs,
  int concurrency,
  Future<void> Function(T) run,
) async {
  var next = 0;
  Object? failure;
  Future<void> worker() async {
    while (failure == null) {
      final i = next++;
      if (i >= jobs.length) return;
      try {
        await run(jobs[i]);
      } catch (e) {
        failure ??= e;
      }
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  // ignore: only_throw_errors
  if (failure != null) throw failure!;
}

Future<void> main(List<String> args) async {
  String opt(String name, String def) {
    final i = args.indexOf('--$name');
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : def;
  }

  final out = Directory(opt('out', 'site'));
  final maxCalls = int.parse(opt('max-calls', '9000'));
  final reserve = int.parse(opt('reserve', '3000'));
  final concurrency = int.parse(opt('concurrency', '6'));
  final hours = int.parse(opt('hours', '27'));
  _key = (Platform.environment['KHOA_KEY'] ?? '').trim();
  if (_key.isEmpty) {
    stderr.writeln('KHOA_KEY 환경변수(해양조사원 인증키)가 없습니다.');
    exit(64);
  }

  final budget = _Budget(maxCalls, reserve);
  // 한국시간 벽시계 — 실행 기계의 시간대와 상관없이
  final now = DateTime.now().toUtc().add(const Duration(hours: 9));
  final frames = framesToBuild(now, hoursAhead: hours);
  final wanted = {for (final f in frames) frameKey(f)};

  final tcDir = Directory('${out.path}/tc')..createSync(recursive: true);

  // 오래된 장면·미완성 폴더 정리
  for (final e in tcDir.listSync()) {
    if (e is! Directory) continue;
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name.endsWith('.tmp') || !wanted.contains(name)) {
      e.deleteSync(recursive: true);
    }
  }

  // 바다가 아닌(점이 없는) 0.1° 타일 기록 — 7일마다 다시 확인
  final stateFile = File('${out.path}/_state.json');
  var empties = <String>{};
  var checked = '';
  if (stateFile.existsSync()) {
    try {
      final s =
          jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
      checked = (s['checked'] as String?) ?? '';
      final age = checked.isEmpty
          ? null
          : now.difference(DateTime.parse(checked)).inDays;
      if (age != null && age < 7) {
        empties = {...((s['empty'] as List?) ?? const []).cast<String>()};
      }
    } catch (_) {}
  }
  if (empties.isEmpty) checked = now.toIso8601String().substring(0, 10);

  final fine = tilesOfSize(0.1);
  final coarse = [for (final s in publishedSizes.skip(1)) ...tilesOfSize(s)];
  stdout.writeln(
    '장면 ${frames.length}개 · 타일 ${tileCounts()} · 건너뛸 빈 타일 ${empties.length}개',
  );

  var built = 0, skipped = 0;
  var firstFailure = false;
  for (final t in frames) {
    final key = frameKey(t);
    final done = File('${tcDir.path}/$key/_ok');
    if (done.existsSync()) {
      skipped++;
      continue;
    }
    if (budget.exhausted) break;
    final tmp = Directory('${tcDir.path}/$key.tmp');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    final all = <PrefetchPoint>[];
    final byTile = <String, List<PrefetchPoint>>{};
    final newEmpty = <String>{};
    try {
      final todo = fine.where((f) => !empties.contains(f.shortId)).toList();
      await _pool<PrefetchTile>(todo, concurrency, (f) async {
        final pts = await _fetchTile(f, t, budget);
        byTile[f.shortId] = pts;
        all.addAll(pts);
        if (pts.isEmpty) newEmpty.add(f.shortId);
      });
    } catch (e) {
      stderr.writeln(
        '장면 $key 실패: ${e is StateError ? e.message : e.runtimeType}',
      );
      tmp.deleteSync(recursive: true);
      if (built == 0 && skipped == 0) firstFailure = true;
      break;
    }
    // 파일 쓰기 — 0.1° 전부(빈 타일 포함), 0.25°·0.5° 솎은 것
    for (final f in fine) {
      File(
        '${tmp.path}/${f.fileName}',
      ).writeAsStringSync(packTile(byTile[f.shortId] ?? const []));
    }
    for (final c in coarse) {
      File(
        '${tmp.path}/${c.fileName}',
      ).writeAsStringSync(packTile(thinForTile(c, all)));
    }
    File('${tmp.path}/_ok').writeAsStringSync(key);
    final dest = Directory('${tcDir.path}/$key');
    if (dest.existsSync()) dest.deleteSync(recursive: true);
    tmp.renameSync(dest.path);
    empties.addAll(newEmpty);
    stateFile.writeAsStringSync(
      jsonEncode({'checked': checked, 'empty': empties.toList()..sort()}),
    );
    built++;
    stdout.writeln(
      '장면 $key 완료 · 점 ${all.length} · 지금까지 호출 ${budget.calls}'
      '${budget.remaining != null ? ' · 오늘 남은 ${budget.remaining}' : ''}',
    );
  }

  // 색인 — 모든 타일이 갖춰진 장면만
  final ready = <String>[
    for (final f in frames)
      if (File('${tcDir.path}/${frameKey(f)}/_ok').existsSync()) frameKey(f),
  ];
  File(
    '${out.path}/index.json',
  ).writeAsStringSync(buildIndexJson(updated: now, frames: ready));
  stdout.writeln(
    '끝 — 새로 $built개 · 이미 있음 $skipped개 · 색인 ${ready.length}개 · 호출 ${budget.calls}회',
  );
  _http.close(force: true);
  if (firstFailure && ready.isEmpty) exit(2);
}
