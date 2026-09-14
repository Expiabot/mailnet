/// Builds IMAP SEARCH criteria from what the user picked on screen.
///
/// Ported from `buildCriteria()` in the MailNet web server (`server.js`) so the
/// phone and the desktop version select exactly the same messages.
class MailFilters {
  const MailFilters({
    this.from = '',
    this.subject = '',
    this.olderThanDays = 0,
    this.largerThanMb = 0,
    this.unreadOnly = false,
    this.hasAttachment = false,
  });

  final String from;
  final String subject;
  final int olderThanDays;
  final int largerThanMb;
  final bool unreadOnly;
  final bool hasAttachment;

  bool get isEmpty =>
      from.trim().isEmpty &&
      subject.trim().isEmpty &&
      olderThanDays <= 0 &&
      largerThanMb <= 0 &&
      !unreadOnly &&
      !hasAttachment;

  MailFilters copyWith({
    String? from,
    String? subject,
    int? olderThanDays,
    int? largerThanMb,
    bool? unreadOnly,
    bool? hasAttachment,
  }) =>
      MailFilters(
        from: from ?? this.from,
        subject: subject ?? this.subject,
        olderThanDays: olderThanDays ?? this.olderThanDays,
        largerThanMb: largerThanMb ?? this.largerThanMb,
        unreadOnly: unreadOnly ?? this.unreadOnly,
        hasAttachment: hasAttachment ?? this.hasAttachment,
      );

  /// The IMAP SEARCH argument. With nothing selected this is `ALL`, which
  /// matches every message in the folder — the caller is expected to warn
  /// before acting on that.
  ///
  /// [now] exists so tests can pin the date arithmetic.
  String toSearchCriteria({DateTime? now}) {
    final parts = <String>[];

    final fromTerm = from.trim();
    if (fromTerm.isNotEmpty) parts.add('FROM ${_quote(fromTerm)}');

    final subjectTerm = subject.trim();
    if (subjectTerm.isNotEmpty) parts.add('SUBJECT ${_quote(subjectTerm)}');

    if (olderThanDays > 0) {
      final cutoff =
          (now ?? DateTime.now()).subtract(Duration(days: olderThanDays));
      parts.add('BEFORE ${_imapDate(cutoff)}');
    }

    if (largerThanMb > 0) parts.add('LARGER ${largerThanMb * 1024 * 1024}');

    if (unreadOnly) parts.add('UNSEEN');

    // Approximation: multipart/mixed almost always means "has attachments".
    // Same caveat as the web version.
    if (hasAttachment) parts.add('HEADER Content-Type "multipart/mixed"');

    return parts.isEmpty ? 'ALL' : parts.join(' ');
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// IMAP dates are `dd-MMM-yyyy` with English month names, always — the
  /// device locale must not leak in here or the server rejects the search.
  static String _imapDate(DateTime d) {
    final day = d.day.toString().padLeft(2, '0');
    return '$day-${_months[d.month - 1]}-${d.year}';
  }

  static String _quote(String value) {
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }
}
