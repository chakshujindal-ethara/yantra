// Tag vocabulary - HANDOVER 4.3.
//
// One shared vocabulary across every generator, grouped by facet prefix.
//
// The merge action is not housekeeping: similarity detection compares tag
// sets, so two generators tagged `tool:figma` and `tool:Figma` read as
// unrelated and the duplicate-SOP warning never fires. A near-duplicate tag is
// therefore a correctness problem, which is why it gets a banner.
import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../widgets/import_sheet.dart';
import '../../widgets/buttons.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../theme.dart';

class TagsScreen extends StatelessWidget {
  final AppStore store;

  const TagsScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, _) {
        final List<Tag> all = store.tags;

        // Insertion-ordered so the facets appear in the order the vocabulary
        // introduces them rather than alphabetically, which would reshuffle
        // the page every time a tag is added.
        final Map<String, List<Tag>> facets = <String, List<Tag>>{};
        for (final Tag tag in all) {
          facets.putIfAbsent(tag.facet, () => <Tag>[]).add(tag);
        }

        final List<Tag> strays = all.where((Tag x) => !x.isCanonical).toList();
        final int canonical = all.length - strays.length;

        Tag? most;
        for (final Tag x in all) {
          if (x.isCanonical && (most == null || x.uses > most.uses)) most = x;
        }

        return PageBody(
          children: <Widget>[
            // No breadcrumb here: this IS a root destination, and the shell
            // already prints "Admin / <page>" in its top bar. Repeating it
            // put the same words on screen three times in 100px.
            PageHead(
              'Tag Vocabulary',
              sub:
                  'One shared vocabulary across every generator. Facet '
                  'prefixes keep it navigable.',
              actions: <Widget>[
                // Tags is a read-only surface for a Manager: the vocabulary is
                // authored, and every action here calls an Admin-only route.
                if (store.can(Capability.authoring))
                  Btn(
                    'Import',
                    tooltip:
                        'Load tags from a CSV. Keys are canonicalised the same '
                        'way extraction writes them, so an imported tag and an '
                        'extracted one meaning the same thing land on one '
                        'record instead of becoming near-duplicates.',
                    onPressed: () => showImportSheet(
                      context,
                      store,
                      entity: ImportEntity.tags,
                    ),
                  ),
                // Odoo's "Normalize Tags". Endpoint and client method both
                // existed with no caller, so the console could point out
                // near-duplicates and offer no way to resolve them. The tooltip
                // states the cost up front because the effect outlives its own
                // feedback: the re-extraction keeps moving for minutes after
                // the toast.
                if (store.can(Capability.authoring))
                  Btn(
                    'Normalize Vocabulary',
                    icon: Icons.auto_fix_high_outlined,
                    busy: store.isBusy('normalizetags'),
                    onPressed: store.normalizeTags,
                    tooltip:
                        'Tidy the whole shared vocabulary, in two passes. '
                        'First an LLM clusters true synonyms across every '
                        'generator, folds the spelling variants onto one '
                        'canonical tag and refreshes the readable names - it '
                        'reads what is actually there rather than a fixed '
                        'synonym list. Then every generator carrying tags is '
                        're-extracted against the cleaned vocabulary.\n\n'
                        'The point is compounding: a cleaner shared vocabulary '
                        'means the NEXT project lands on the same words, so '
                        'similar-project ranking keeps improving.\n\n'
                        'Costs one LLM call, and the re-extraction settles over '
                        'several minutes AFTER the toast.',
                  ),
              ],
            ),
            KpiStrip(<Widget>[
              Kpi(
                label: 'Tags',
                value: '${all.length}',
                sub: 'across ${facets.length} facets',
              ),
              Kpi(
                label: 'Canonical',
                value: '$canonical',
                sub: 'in active use',
              ),
              Kpi(
                label: 'Near-duplicates',
                value: '${strays.length}',
                sub: strays.isEmpty ? 'none' : 'should be merged',
                valueColor: all.isEmpty
                    ? null
                    : (strays.isEmpty ? t.successText : t.warnText),
              ),
              // THE COUNT IS THE NUMERAL, and the tag qualifies it.
              //
              // This card had the tag NAME in the display size its three
              // neighbours use for a figure, so a perfectly ordinary tag like
              // `image-evaluation` rendered several times the width of a "7"
              // and pulled the whole strip out of shape - and a longer one
              // ellipsised on top of that. Shortening the name only moved the
              // problem: a name is not a magnitude, and no amount of trimming
              // makes it read as one. The uses ARE a magnitude, they are what
              // "most used" is measured in, and they sit on the same baseline
              // as every other card.
              Kpi(
                label: 'Most used',
                value: most == null ? '-' : '${most.uses}',
                sub: most == null
                    ? 'nothing tagged yet'
                    : '${_shortName(most.name, most.facet)} '
                          '· ${_headingFor(most.facet)}',
              ),
            ]),
            if (strays.isNotEmpty) ...<Widget>[
              Notice(
                tone: Tone.warn,
                strong:
                    '${strays.length} tags look like spelling variants of '
                    'a canonical tag.',
                text:
                    'Merging keeps similarity detection honest - two '
                    'generators tagged tool:figma and tool:Figma read as '
                    'unrelated.',
                actions: <Widget>[
                  if (store.can(Capability.authoring))
                    Btn(
                      'Merge All',
                      tooltip:
                          'Fold every near-duplicate into the canonical tag it '
                          'was matched to, in one pass. A pure database '
                          'operation - it makes no LLM call and costs nothing. '
                          'Every project already using a folded tag is '
                          'repointed at the survivor.',
                      size: BtnSize.sm,
                      onPressed: store.mergeAllTags,
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (facets.isEmpty)
              const Panel(
                child: EmptyLine(
                  'No tags yet. Extract the skills on a generator and its '
                  'vocabulary lands here.',
                ),
              )
            else
              Stack16(
                facets.entries
                    .map(
                      (MapEntry<String, List<Tag>> e) => _FacetPanel(
                        store: store,
                        facet: e.key,
                        tags: e.value,
                      ),
                    )
                    .toList(),
              ),
          ],
        );
      },
    );
  }
}

/// The facet as a display heading: `output-format` -> `Output format`.
///
/// Hyphens become spaces because the facet is a slug, not prose, and only the
/// first word is capitalised so a multi-word facet does not read as a title.
String _headingFor(String facet) {
  if (facet.isEmpty) return 'Other';
  final String spaced = facet.replaceAll('-', ' ');
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// A tag without its facet prefix: `domain:ui-annotation` -> `ui-annotation`.
///
/// Falls back to the full name when the prefix is absent, so an unfaceted tag
/// still shows something. Nullable in, because `Tag.mergeInto` is null for a
/// canonical tag.
String _shortName(String? name, String facet) {
  final String full = name ?? '';
  final String prefix = '$facet:';
  return full.startsWith(prefix) ? full.substring(prefix.length) : full;
}

/// One panel per facet prefix: Tag / Used by / Status / action.
class _FacetPanel extends StatelessWidget {
  final AppStore store;
  final String facet;
  final List<Tag> tags;

  const _FacetPanel({
    required this.store,
    required this.facet,
    required this.tags,
  });

  @override
  Widget build(BuildContext context) => Panel(
    // "Domain", not "domain:" - the heading already names the facet, so
    // repeating the prefix on every row below is noise.
    title: _headingFor(facet),
    headActions: <Widget>[TagChip('${tags.length}')],
    flush: true,
    child: DataGrid(
      minWidth: 720,
      emptyMessage: 'No tags under this facet.',
      emptyIcon: Icons.sell_outlined,
      cols: const <Col>[
        Col('Tag', flex: 3),
        Col('Used by', width: 96, numeric: true),
        Col('Status', flex: 2),
        Col('', width: 132, numeric: true),
      ],
      rows: tags.map((Tag tag) {
        return GridRow(<Widget>[
          // The bare name: the panel heading already says the facet.
          Mono(_shortName(tag.name, facet), weight: FontWeight.w600),
          Mono('${tag.uses}'),
          tag.isCanonical
              ? const Pill('Canonical', Tone.ok)
              // Shortened like the name beside it.
              : Pill(
                  'Merge into ${_shortName(tag.mergeInto, facet)}',
                  Tone.warn,
                ),
          // TWO REASONS FOR THE SAME CELL, and they read the same on screen.
          //
          // Renaming a canonical tag rewrites it across every generator that
          // uses it, and the module has no rename route yet. A "Rename" button
          // that only explains why it will not rename is worse than no button:
          // it reads as broken. Stated as a fact instead, next to the count
          // that makes the cost concrete.
          //
          // A read-only Manager gets that same fact for EVERY tag: merging
          // calls an Admin-only route, and the usage count is the useful thing
          // to show where the button would have been.
          tag.isCanonical || !store.can(Capability.authoring)
              ? Text(
                  tag.uses > 0 ? 'used ${tag.uses}x' : 'unused',
                  style: context.type.bodyMuted,
                  textAlign: TextAlign.right,
                )
              : Btn(
                  'Merge into ${_shortName(tag.mergeInto, facet)}',
                  tooltip:
                      'Repoint every project using this spelling at the '
                      'canonical tag, then delete this one. Merging targets '
                      'the RECORD, not the text, so two tags that read alike '
                      'after normalising cannot be confused.',
                  size: BtnSize.sm,
                  // The FULL name goes to the store: the server keys on
                  // the faceted form, and sending the short one would
                  // merge into a tag that does not exist.
                  onPressed: () => store.mergeTag(tag.name),
                ),
        ]);
      }).toList(),
    ),
  );
}
