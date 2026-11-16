/// Dates, times and durations the way a worker reads them. Everything is shown in the device's local
/// time; the pay week is defined in IST and labelled as such where it matters.
library;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String two(int n) => n.toString().padLeft(2, '0');

/// `3 Nov` or `3 Nov 2025` when the year differs from [now]'s.
String shortDate(DateTime d, {DateTime? now}) {
  final local = d.toLocal();
  final year = (now ?? DateTime.now()).year == local.year ? '' : ' ${local.year}';
  return '${local.day} ${_months[local.month - 1]}$year';
}

/// `Mon 3 Nov, 14:05`.
String dateTime(DateTime d) {
  final l = d.toLocal();
  return '${_weekdays[l.weekday - 1]} ${l.day} ${_months[l.month - 1]}, ${two(l.hour)}:${two(l.minute)}';
}

/// `1 – 7 Nov` for a window; both ends inclusive on the calendar.
String dateRange(DateTime start, DateTime end, {DateTime? now}) {
  final s = start.toLocal();
  // the end instant is the first second of the next period; show the last calendar day it covers
  final e = end.toLocal().subtract(const Duration(seconds: 1));
  if (s.month == e.month && s.year == e.year) return '${s.day} – ${shortDate(e, now: now)}';
  return '${shortDate(s, now: now)} – ${shortDate(e, now: now)}';
}

/// IST is UTC+5:30 all year round (no daylight saving): pay weeks are defined in it.
const _istOffset = Duration(hours: 5, minutes: 30);

/// [d] as a UTC value whose fields read as IST wall-clock time.
DateTime _ist(DateTime d) => d.toUtc().add(_istOffset);

String _istDay(DateTime fields, DateTime now) =>
    '${fields.day} ${_months[fields.month - 1]}${fields.year == _ist(now).year ? '' : ' ${fields.year}'}';

/// `26 Oct – 1 Nov IST` for a pay window, whatever the device's zone: the payout week runs Monday 00:00
/// to Sunday 23:59 IST. Both ends inclusive on the calendar.
String payWindowRange(DateTime start, DateTime end, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final s = _ist(start);
  final e = _ist(end).subtract(const Duration(seconds: 1)); // the end instant opens the next week
  if (s.month == e.month && s.year == e.year) return '${s.day} – ${_istDay(e, n)} IST';
  return '${_istDay(s, n)} – ${_istDay(e, n)} IST';
}

/// `2 Nov IST`: one day of a pay window.
String istDate(DateTime d, {DateTime? now}) => '${_istDay(_ist(d), now ?? DateTime.now())} IST';

/// `just now`, `5 min ago`, `3 h ago`, `yesterday`, `3 Nov`.
String relative(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final diff = n.difference(d);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays == 1) return 'yesterday';
  if (diff.inDays < 7) return '${diff.inDays} days ago';
  return shortDate(d, now: n);
}

/// `in 2 days`, `in 5 h`, `in 12 min`, `now`.
String untilShort(DateTime d, {DateTime? now}) {
  final diff = d.difference(now ?? DateTime.now());
  if (diff.isNegative) return 'now';
  if (diff.inMinutes < 60) return 'in ${diff.inMinutes} min';
  if (diff.inHours < 48) return 'in ${diff.inHours} h';
  return 'in ${diff.inDays} days';
}

/// `1:05:09` or `05:09` for a countdown.
String countdown(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// `4 h`, `45 min`, `1 h 30 min`.
String minutesLabel(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// `640 KB` under a megabyte, else `12.5 MB`.
String fileSize(int bytes) => bytes < 1024 * 1024 ? '${(bytes / 1024).ceil()} KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// `guideline_miss` → `Guideline miss`.
String humanize(String code) {
  if (code.isEmpty) return code;
  final words = code.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  return words[0].toUpperCase() + words.substring(1);
}

/// Initials for an avatar: `worker1` → `W`, `Asha Rao` → `AR`.
String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// `2026-11-30` as a UTC midnight, or null when empty; throws on anything else.
DateTime? parseDay(String text, {String label = 'Date'}) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t);
  if (m == null) throw FormatException('$label must be a date like 2026-11-30');
  final d = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  if (d.month != int.parse(m[2]!)) throw FormatException('$label is not a real date');
  return d;
}

String dayText(DateTime? d) => d == null ? '' : '${d.toUtc().year}-${two(d.toUtc().month)}-${two(d.toUtc().day)}';
