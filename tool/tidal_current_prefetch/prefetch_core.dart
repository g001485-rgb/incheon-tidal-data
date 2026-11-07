// 조류(수치조류도 예측) 미리 받기 — 순수 계산 부분(파일·네트워크 없음).
//
// 국립해양조사원 서버는 요청 하나에 1.6~4.5초가 걸리고 하루 20,000회를 앱 사용자 전체가 나눠 쓴다. 그래서
// 이 도구가 인천 바다의 예측값을 미리 받아 정적 파일로 만들어 두고, 앱은 그 파일을 먼저 읽는다(없으면 서버 직접 호출).
//
// 이 파일은 Flutter에 기대지 않는다 — 앱 저장소의 시험이 불러 확인하고, 자료 저장소(공개)에도 그대로 복사해 쓴다.
// 파일 모양(앱의 lib/features/tidal_current/tidal_current_static.dart가 읽는 것과 같다):
//   index.json                      {"v":1,"updated":"…","bounds":[W,S,E,N],"sizes":[0.1,0.25,0.5],"stepMin":30,"frames":["202611071800",…]}
//   tc/{frame}/{size}_{ix}_{iy}.json {"p":[[위도,경도,유속cm/s,유향도],…]}   예: tc/202611071800/0.10_1263_372.json
// frame은 한국시간 yyyyMMddHHmm(30분 간격), 타일 번호는 앱의 TidalCurrentTile과 같다(서·남쪽 경계 = 번호 × 크기).

import 'dart:math' as math;

/// 미리 받는 범위(서해 인천 바다 — 백령도·연평도·덕적도·경기만). 이 범위를 완전히 덮는 타일만 만든다.
const double coverMinLon = 124.4;
const double coverMaxLon = 127.0;
const double coverMinLat = 36.9;
const double coverMaxLat = 38.1;

/// 장면 간격(분).
const int stepMinutes = 30;

/// 만드는 타일 크기(도) — 서버에서 받는 것은 맨 앞(0.1)뿐이고 나머지는 거기서 솎아 만든다.
const List<double> publishedSizes = [0.1, 0.25, 0.5];

/// 유속(cm/s)이 이보다 크면 비정상 값으로 보고 버린다(앱과 같은 기준).
const double maxPlausibleCmS = 500;

/// 한 점 — 위도·경도·유속(cm/s)·유향(흘러가는 쪽, 진북 기준 시계방향 0 이상 360 미만).
class PrefetchPoint {
  final double lat;
  final double lon;
  final double speedCmS;
  final double dirDeg;
  const PrefetchPoint(this.lat, this.lon, this.speedCmS, this.dirDeg);
}

/// 타일 하나(앱의 TidalCurrentTile과 같은 뜻).
class PrefetchTile {
  final double size;
  final int ix;
  final int iy;
  const PrefetchTile(this.size, this.ix, this.iy);

  static double _r(double v) => double.parse(v.toStringAsFixed(5));
  double get minX => _r(ix * size);
  double get maxX => _r((ix + 1) * size);
  double get minY => _r(iy * size);
  double get maxY => _r((iy + 1) * size);

  String get fileName => '${size.toStringAsFixed(2)}_${ix}_$iy.json';

  /// 서버 요청에 쓰는 (이 앱과 같은) 식별 — 0.1도 타일은 '1263:372'.
  String get shortId => '$ix:$iy';
}

/// 정해진 범위를 완전히 덮는 [size] 타일들.
List<PrefetchTile> tilesOfSize(double size) {
  const eps = 1e-9;
  final x0 = (coverMinLon / size - eps).ceil();
  final x1 = (coverMaxLon / size + eps).floor() - 1;
  final y0 = (coverMinLat / size - eps).ceil();
  final y1 = (coverMaxLat / size + eps).floor() - 1;
  return [
    for (var ix = x0; ix <= x1; ix++)
      for (var iy = y0; iy <= y1; iy++) PrefetchTile(size, ix, iy),
  ];
}

/// `yyyyMMddHHmm`(한국시간 벽시계).
String frameKey(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}';
}

/// [t]를 30분 단위로 내린다(초 이하 버림).
DateTime floorToStep(DateTime t) => DateTime(
  t.year,
  t.month,
  t.day,
  t.hour,
  (t.minute ~/ stepMinutes) * stepMinutes,
);

/// 만들어 둘 장면 시각들 — [now]를 30분으로 내린 시각의 30분 앞부터 +[hoursAhead]시간까지.
/// 앱은 지금(가장 가까운 30분)에서 +24시간까지 보므로 여유를 둔다.
List<DateTime> framesToBuild(DateTime now, {int hoursAhead = 27}) {
  final start = floorToStep(now).subtract(const Duration(minutes: stepMinutes));
  final n = (hoursAhead * 60 + stepMinutes) ~/ stepMinutes + 1;
  return [
    for (var i = 0; i < n; i++) start.add(Duration(minutes: i * stepMinutes)),
  ];
}

/// 서버 응답 JSON → 점 목록(앱의 TidalCurrentParser와 같은 검사). 오류 응답이면 [FormatException].
List<PrefetchPoint> parseApiBody(Map<String, dynamic> json) {
  final result = json['result'];
  if (result is! Map) throw const FormatException('응답 형식 오류');
  final error = result['error'];
  if (error != null) throw FormatException('서버 오류: $error');
  final data = result['data'];
  if (data == null) return const [];
  if (data is! List) throw const FormatException('응답 형식 오류');
  double? num_(Object? v) {
    if (v == null) return null;
    final d = v is num ? v.toDouble() : double.tryParse(v.toString().trim());
    return (d == null || d.isNaN || d.isInfinite) ? null : d;
  }

  final out = <PrefetchPoint>[];
  for (final item in data) {
    if (item is! Map) continue;
    final lat = num_(item['pre_lat']);
    final lon = num_(item['pre_lon']);
    final speed = num_(item['current_speed']);
    final dir = num_(item['current_dir']);
    if (lat == null || lon == null || speed == null || dir == null) continue;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) continue;
    if (speed < 0 || speed > maxPlausibleCmS) continue;
    if (dir < 0 || dir > 360) continue;
    out.add(PrefetchPoint(lat, lon, speed, dir >= 360 ? 0 : dir));
  }
  return out;
}

/// 큰 타일 [tile]의 점 — 전체 점 [all] 중 타일 안(서·남쪽 경계 포함, 동·북쪽 경계 제외)의 점을
/// 칸(타일 한 변/12)마다 유속이 가장 큰 하나만 남긴다(서버가 큰 영역에서 약 100점으로 솎아 주는 것과 비슷하게).
List<PrefetchPoint> thinForTile(
  PrefetchTile tile,
  Iterable<PrefetchPoint> all,
) {
  final cell = tile.size / 12;
  final best = <int, PrefetchPoint>{};
  for (final p in all) {
    if (p.lon < tile.minX || p.lon >= tile.maxX) continue;
    if (p.lat < tile.minY || p.lat >= tile.maxY) continue;
    final cx = ((p.lon - tile.minX) / cell).floor();
    final cy = ((p.lat - tile.minY) / cell).floor();
    final k = cx * 1000 + cy;
    final cur = best[k];
    if (cur == null || p.speedCmS > cur.speedCmS) best[k] = p;
  }
  final out = best.values.toList()
    ..sort((a, b) {
      final c = a.lat.compareTo(b.lat);
      return c != 0 ? c : a.lon.compareTo(b.lon);
    });
  return out;
}

/// 숫자를 군더더기 없이(끝의 0 제거).
String _num(double v, int digits) {
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// 타일 파일 내용 — `{"p":[[위도,경도,유속,유향],…]}`.
String packTile(Iterable<PrefetchPoint> points) {
  final b = StringBuffer('{"p":[');
  var first = true;
  for (final p in points) {
    if (!first) b.write(',');
    first = false;
    b.write(
      '[${_num(p.lat, 5)},${_num(p.lon, 5)},${_num(p.speedCmS, 1)},${_num(p.dirDeg, 1)}]',
    );
  }
  b.write(']}');
  return b.toString();
}

/// 색인 파일 내용. [frames]는 모든 타일이 갖춰진 장면 시각들(오름차순).
String buildIndexJson({
  required DateTime updated,
  required List<String> frames,
}) {
  final sorted = [...frames]..sort();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${updated.year}-${two(updated.month)}-${two(updated.day)}T'
      '${two(updated.hour)}:${two(updated.minute)}+09:00';
  return '{"v":1,"updated":"$stamp",'
      '"bounds":[$coverMinLon,$coverMinLat,$coverMaxLon,$coverMaxLat],'
      '"sizes":[${publishedSizes.join(',')}],'
      '"stepMin":$stepMinutes,'
      '"frames":[${sorted.map((f) => '"$f"').join(',')}]}';
}

/// 시험·점검용 — 만들 타일 수(크기별).
Map<double, int> tileCounts() => {
  for (final s in publishedSizes) s: tilesOfSize(s).length,
};

/// 반올림 도움(시험용 노출).
double roundTo(double v, int digits) {
  final m = math.pow(10, digits).toDouble();
  return (v * m).round() / m;
}
