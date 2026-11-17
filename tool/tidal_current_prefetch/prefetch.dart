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
//   --hours <수>        지금부터 몇 시간 앞까지 만들지(기본 48). 앱 슬라이더는 +24시간까지인데 GitHub 예약 실행이 늦거나
//                       빠져 실제 갱신 간격이 평균 11시간·최대 15.7시간이었다(2026-11-18 확인) — 21시간 넘게 끊겨도
//                       +24시간이 남게 여유를 둔다. 이미 만든 장면은 다시 받지 않아 평소 하루 호출 수는 그대로다
//                       (하루 새 장면 48개).
//   --min-ahead <수>    끝난 뒤 색인의 마지막 장면이 지금+이 시간(기본 24, --hours보다 크면 --hours)에 못 미치면
//                       종료 코드 1(받은 만큼은 색인에 올린다). 인증키 만료·한도로 일부만 받은 것을 알리는 빨간불.
//
// 종료 코드: 0 정상 · 1 일부만 받음(위 기준 미달이거나, 받으려 한 타일이 모두 빈 답이라 버린 장면이 있음 — 결과 폴더는 올려도 된다)
//            · 2 쓸 장면이 하나도 없음(올리지 않는다) · 64 인증키 없음.
//
// 이미 만든 장면은 건너뛰므로(폴더를 보관해 두면) 다시 실행해도 새 장면만 받는다. 인증키는 출력·파일에 남기지 않는다.
// 서버는 요청 하나에 약 100점만 돌려주므로 0.1° 타일(312칸)로 나눠 부르고, 바다가 아닌 타일은 처음 한 번만 확인해
// 이후엔 건너뛴다(_state.json). 0.25°·0.5° 타일은 0.1° 점들에서 솎아 만든다.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
  var rejected = false;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (b.exhausted) throw StateError('호출 한도에 닿았다');
    try {
      return parseApiBody(await _fetch(t, time, b));
    } on StateError {
      rethrow;
    } catch (e) {
      // 원인을 알 수 있게 종류와 짧은 설명을 남기되, 공개 로그라 인증키가 어떤 모양으로도 남지 않게 한다 —
      // dart:io HttpException은 문구 끝에 'uri = …?ServiceKey=<인코딩된 키>'를 붙인다(검토 TA-5)
      last = redactErrorText('${e.runtimeType}: $e', _key);
      // 서버가 오류 문구나 이상한 본문을 돌려준 경우(FormatException)는 되풀이해도 같으니 한 번만 더 본다
      rejected = e is FormatException;
      if (rejected && attempt >= 1) break;
      await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
    }
  }
  final text = '타일 ${t.shortId} 받기 실패(${last ?? '?'})';
  if (rejected) throw _TileRejected(text);
  throw StateError(text);
}

/// 서버가 이 타일 요청을 받아들이지 않았다(모델 범위 밖 등) — 다른 타일이 멀쩡하면 이 타일만 비운다.
class _TileRejected implements Exception {
  final String message;
  const _TileRejected(this.message);
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
  final hours = int.parse(opt('hours', '48'));
  final minAhead = int.parse(opt('min-ahead', '24'));
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
  var allEmptyScene = false; // 모든 타일이 빈 답이라 버린 장면이 있었다
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
      final rejected = <String>[];
      await _pool<PrefetchTile>(todo, concurrency, (f) async {
        try {
          final pts = await _fetchTile(f, t, budget);
          byTile[f.shortId] = pts;
          all.addAll(pts);
          if (pts.isEmpty) newEmpty.add(f.shortId);
        } on _TileRejected catch (r) {
          // 서버가 받아주지 않는 타일(모델 범위 가장자리 등) — 빈 타일로 두고 다음부터 건너뛴다
          byTile[f.shortId] = const [];
          newEmpty.add(f.shortId);
          rejected.add(r.message);
          // 처음부터 많이 거절되면 인증키·한도 문제 — 호출을 더 낭비하지 않고 바로 멈춘다
          if (rejected.length > 30) {
            throw StateError('거절된 타일이 너무 많다: ${rejected.first}');
          }
        }
      });
      if (rejected.isNotEmpty) {
        stdout.writeln(
          '서버가 받아주지 않은 타일 ${rejected.length}개 — '
          '예: ${redactErrorText(rejected.first, _key, maxLength: 400)}',
        );
      }
      // 거의 다 거절이면 인증키·한도 문제이지 가장자리가 아니다 — 장면 전체를 실패로 본다
      if (rejected.length > todo.length * 0.1) {
        throw StateError(
          '거절된 타일이 너무 많다(${rejected.length}/${todo.length}): ${rejected.first}',
        );
      }
      // 받으려 한 타일이 하나도 점을 안 돌려줬다 — 육지 칸은 원래 비지만 바다 칸까지 전부 비는 일은 없다(서버가 그 시각 자료를
      // 아직 안 냈거나 점검 중일 수 있다). 빈 장면을 정상으로 올리고 빈 타일 목록을 7일 고정하지 않도록 이 장면을 실패로 본다.
      // 일부 타일만 빈 것(먼바다 칸 등)은 그대로 둔다(10차 검토 TL10-7).
      if (todo.isNotEmpty && all.isEmpty) {
        allEmptyScene = true;
        throw StateError('받으려 한 타일 ${todo.length}개가 모두 빈 답이라 이 장면을 쓰지 않는다');
      }
    } catch (e) {
      // 문구는 이미 가렸지만 공개 로그로 나가는 마지막 관문에서 한 번 더 거른다
      final why = e is StateError ? e.message : '${e.runtimeType}';
      stderr.writeln(
        '장면 $key 실패: ${redactErrorText(why, _key, maxLength: 400)}',
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
  // 쓸 장면이 하나도 없다 — 올리지 않는다(예전 배포본이 그대로 남는 편이 낫다)
  if (ready.isEmpty) {
    stderr.writeln('색인에 장면이 하나도 없습니다${firstFailure ? '(첫 장면부터 실패)' : ''}.');
    exit(2);
  }
  // 일부만 받았다(인증키 만료·하루 한도·서버 차단 등) — 받은 만큼은 올리되 빨간불로 알린다
  final short = aheadShortfall(
    ready,
    now,
    minAheadHours: math.min(minAhead, hours),
  );
  if (short != null) {
    stderr.writeln(
      '색인의 마지막 장면 ${ready.last}이 기준 $short(지금+${math.min(minAhead, hours)}시간)보다 이릅니다 — '
      '일부만 받았습니다(인증키 만료·하루 호출 한도·서버 차단 확인).',
    );
    exit(1);
  }
  // 기준은 채웠어도 어떤 장면이 전부 빈 답이었다면 조용히 넘기지 않는다 — 앞선 장면(이미 있던 파일)은 그대로 올리고 빨간불만 켠다.
  if (allEmptyScene) {
    stderr.writeln(
      '어떤 장면은 모든 타일이 빈 답이라 버렸습니다(서버 점검·자료 미게시 확인). 이미 받은 장면까지만 올렸습니다.',
    );
    exit(1);
  }
}
