import 'package:flutter/material.dart';

import '../mail/mail_filters.dart';
import '../mail/mail_service.dart';
import '../mail/models.dart';
import '../ui/theme.dart';
import 'results_screen.dart';
import 'senders_screen.dart';

class FiltersScreen extends StatefulWidget {
  const FiltersScreen({
    super.key,
    required this.service,
    required this.email,
    required this.listing,
  });

  final MailService service;
  final String email;
  final FolderListing listing;

  @override
  State<FiltersScreen> createState() => _FiltersScreenState();
}

class _FiltersScreenState extends State<FiltersScreen> {
  final _from = TextEditingController();
  final _subject = TextEditingController();

  late String _folder;
  int _olderThanDays = 0;
  int _largerThanMb = 0;
  bool _unreadOnly = false;
  bool _hasAttachment = false;
  bool _searching = false;
  String? _error;

  static const _ages = {
    0: '— peu importe',
    7: '1 semaine',
    30: '1 mois',
    90: '3 mois',
    180: '6 mois',
    365: '1 an',
    730: '2 ans',
  };

  static const _sizes = {
    0: '— peu importe',
    1: '1 Mo',
    5: '5 Mo',
    10: '10 Mo',
    25: '25 Mo',
  };

  @override
  void initState() {
    super.initState();
    final folders = widget.listing.folders;
    _folder = folders.any((f) => f.path == 'INBOX')
        ? 'INBOX'
        : (folders.isNotEmpty ? folders.first.path : 'INBOX');
  }

  @override
  void dispose() {
    _from.dispose();
    _subject.dispose();
    super.dispose();
  }

  MailFilters get _filters => MailFilters(
        from: _from.text,
        subject: _subject.text,
        olderThanDays: _olderThanDays,
        largerThanMb: _largerThanMb,
        unreadOnly: _unreadOnly,
        hasAttachment: _hasAttachment,
      );

  String _folderLabel(MailFolder f) {
    if (f.isInbox || f.path == 'INBOX') return '📥  Boîte de réception';
    if (f.isTrash) return '🗑️  ${f.name}';
    if (f.isSent) return '📤  ${f.name}';
    if (f.isDrafts) return '📝  ${f.name}';
    if (f.isJunk) return '🚫  ${f.name}';
    return f.name;
  }

  void _openSenders() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SendersScreen(
          service: widget.service,
          folder: _folder,
          trashPath: widget.listing.trashPath,
        ),
      ),
    );
  }

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final result = await widget.service.search(
        folder: _folder,
        filters: _filters,
      );
      if (!mounted) return;
      setState(() => _searching = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ResultsScreen(
            service: widget.service,
            folder: _folder,
            filters: _filters,
            initialResult: result,
            trashPath: widget.listing.trashPath,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'La recherche a échoué. $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quels mails supprimer ?'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Quitter'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 18, color: scheme.onPrimaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.email,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onPrimaryContainer,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // The filters below assume you already know what to look for. This
          // is the way in for everyone else.
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(Icons.groups_2_outlined, color: scheme.onPrimaryContainer),
              ),
              title: const Text(
                'Qui vous écrit le plus',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Classe le dossier par expéditeur, avec le nombre de mails, '
                'la place occupée et le désabonnement',
                style: TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _searching ? null : _openSenders,
            ),
          ),
          const SizedBox(height: 24),
          const _Label('Dossier'),
          DropdownButtonFormField<String>(
            initialValue: _folder,
            isExpanded: true,
            items: [
              for (final f in widget.listing.folders)
                DropdownMenuItem(value: f.path, child: Text(_folderLabel(f))),
            ],
            onChanged: (v) => setState(() => _folder = v ?? _folder),
          ),
          const SizedBox(height: 20),
          const _Label('L’expéditeur contient…'),
          TextField(
            controller: _from,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'newsletter, amazon, bob@exemple.fr',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          const _Label('L’objet contient…'),
          TextField(
            controller: _subject,
            decoration: const InputDecoration(
              hintText: 'promotion, facture',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Label('Plus vieux que'),
                    DropdownButtonFormField<int>(
                      initialValue: _olderThanDays,
                      isExpanded: true,
                      items: [
                        for (final e in _ages.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) =>
                          setState(() => _olderThanDays = v ?? 0),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Label('Plus lourd que'),
                    DropdownButtonFormField<int>(
                      initialValue: _largerThanMb,
                      isExpanded: true,
                      items: [
                        for (final e in _sizes.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => _largerThanMb = v ?? 0),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _unreadOnly,
            onChanged: (v) => setState(() => _unreadOnly = v ?? false),
            title: const Text('Uniquement les mails non lus'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          CheckboxListTile(
            value: _hasAttachment,
            onChanged: (v) => setState(() => _hasAttachment = v ?? false),
            title: const Text('Uniquement avec pièce jointe'),
            subtitle: const Text(
              'Approximation : détecte les mails « multipart/mixed »',
              style: TextStyle(fontSize: 12),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          if (_filters.isEmpty) ...[
            const SizedBox(height: 12),
            const NoticeBox(
              text: 'Aucun filtre actif : la recherche remontera tous les mails '
                  'du dossier.',
              tone: NoticeTone.warning,
              icon: Icons.warning_amber_rounded,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            NoticeBox(
              text: _error!,
              tone: NoticeTone.danger,
              icon: Icons.error_outline,
            ),
          ],
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          20 + MediaQuery.of(context).padding.bottom,
        ),
        child: FilledButton.icon(
          onPressed: _searching ? null : _search,
          icon: _searching
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.search),
          label: Text(_searching ? 'Recherche…' : 'Rechercher'),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
}
