// French formatting without pulling in `intl` — the app needs three helpers,
// not a localisation stack.

const _shortMonths = [
  'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
  'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
];

String formatDate(DateTime? date) {
  if (date == null) return '—';
  final d = date.toLocal();
  return '${d.day} ${_shortMonths[d.month - 1]} ${d.year % 100}';
}

String formatSize(int bytes) {
  if (bytes <= 0) return '—';
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} Ko';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} Mo';
}

/// Thousands separated by a non-breaking space, as French typography wants.
String formatCount(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// `1 mail` / `3 mails`, so no message ever reads "1 mails".
String plural(int count, String singular, [String? pluralForm]) {
  final word = count > 1 ? (pluralForm ?? '${singular}s') : singular;
  return '${formatCount(count)} $word';
}
