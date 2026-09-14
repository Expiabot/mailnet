import 'package:flutter_test/flutter_test.dart';
import 'package:mailnet/mail/mail_filters.dart';

void main() {
  // Pinned so the date arithmetic is not a moving target.
  final now = DateTime(2026, 9, 13);

  group('critères IMAP', () {
    test('sans filtre, tout le dossier est visé', () {
      expect(const MailFilters().toSearchCriteria(now: now), 'ALL');
      expect(const MailFilters().isEmpty, isTrue);
    });

    test('expéditeur et objet sont cités', () {
      const f = MailFilters(from: 'newsletter', subject: 'promotion');
      expect(
        f.toSearchCriteria(now: now),
        'FROM "newsletter" SUBJECT "promotion"',
      );
    });

    test('les espaces autour des termes sont ignorés', () {
      const f = MailFilters(from: '  amazon  ');
      expect(f.toSearchCriteria(now: now), 'FROM "amazon"');
    });

    test('un terme contenant un guillemet est échappé', () {
      const f = MailFilters(subject: 'le "grand" test');
      expect(f.toSearchCriteria(now: now), r'SUBJECT "le \"grand\" test"');
    });

    test('la date est au format IMAP anglais quelle que soit la locale', () {
      const f = MailFilters(olderThanDays: 30);
      // 13 septembre 2026 moins 30 jours = 14 août 2026.
      expect(f.toSearchCriteria(now: now), 'BEFORE 14-Aug-2026');
    });

    test('le jour est sur deux chiffres', () {
      const f = MailFilters(olderThanDays: 7);
      expect(f.toSearchCriteria(now: now), 'BEFORE 06-Sep-2026');
    });

    test('la taille est convertie en octets', () {
      const f = MailFilters(largerThanMb: 5);
      expect(f.toSearchCriteria(now: now), 'LARGER 5242880');
    });

    test('non lus', () {
      expect(
        const MailFilters(unreadOnly: true).toSearchCriteria(now: now),
        'UNSEEN',
      );
    });

    test('pièce jointe (approximation multipart/mixed)', () {
      expect(
        const MailFilters(hasAttachment: true).toSearchCriteria(now: now),
        'HEADER Content-Type "multipart/mixed"',
      );
    });

    test('les critères se combinent dans un ordre stable', () {
      const f = MailFilters(
        from: 'bob',
        subject: 'facture',
        olderThanDays: 365,
        largerThanMb: 1,
        unreadOnly: true,
        hasAttachment: true,
      );
      expect(
        f.toSearchCriteria(now: now),
        'FROM "bob" SUBJECT "facture" BEFORE 13-Sep-2025 LARGER 1048576 '
        'UNSEEN HEADER Content-Type "multipart/mixed"',
      );
    });

    test('les valeurs nulles ou négatives sont ignorées', () {
      const f = MailFilters(olderThanDays: 0, largerThanMb: -3);
      expect(f.toSearchCriteria(now: now), 'ALL');
    });

    test('isEmpty ne considère pas un terme composé d’espaces', () {
      expect(const MailFilters(from: '   ').isEmpty, isTrue);
      expect(const MailFilters(from: 'a').isEmpty, isFalse);
    });

    test('copyWith ne touche qu’au champ demandé', () {
      const f = MailFilters(from: 'bob', unreadOnly: true);
      final g = f.copyWith(from: 'alice');
      expect(g.from, 'alice');
      expect(g.unreadOnly, isTrue);
    });
  });
}
