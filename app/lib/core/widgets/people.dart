import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../people.dart';
import '../theme/app_theme.dart';

/// A person's name for [id]: [name] when the row carries one, else the people cache's answer, else the
/// short id in mono. The full id is in the tooltip; assistive tech hears the name alone, or the id when
/// no name is known.
class NameOf extends StatelessWidget {
  const NameOf(this.id, {super.key, this.name = '', this.style, this.maxLines = 1});

  final String id;
  final String name;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final cache = AppScope.of(context).people;
    if (name.isNotEmpty) cache.prime(id, name);
    return ListenableBuilder(
      listenable: cache,
      builder: (context, _) {
        final known = name.isNotEmpty ? name : cache.lookup(id)?.name ?? '';
        final text = known.isEmpty
            ? Text(
                shortId(id),
                style: (style ?? const TextStyle()).copyWith(fontFamily: PortalType.familyMono),
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              )
            : Text(known, style: style, maxLines: maxLines, overflow: TextOverflow.ellipsis);
        // a known person is read by name alone; the id stays in the tooltip for sighted lookup
        return Tooltip(
          message: id,
          excludeFromSemantics: known.isNotEmpty,
          child: Semantics(label: known.isEmpty ? 'id $id' : known, excludeSemantics: true, child: text),
        );
      },
    );
  }
}

/// How a row names a person to assistive tech and in labels: [name] when the row carries one, else the
/// people cache's answer, else the short id.
String personLabel(BuildContext context, String id, {String name = ''}) {
  if (name.isNotEmpty) return name;
  final known = AppScope.of(context).people.lookup(id)?.name ?? '';
  return known.isEmpty ? shortId(id) : known;
}

/// An id shown short and mono, with the full id in the tooltip; for rows where no name exists.
class ShortId extends StatelessWidget {
  const ShortId(this.id, {super.key, this.style});
  final String id;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: id,
    child: Text(shortId(id), style: (style ?? Theme.of(context).textTheme.bodySmall)?.copyWith(fontFamily: PortalType.familyMono)),
  );
}
