/// Pages the shell keeps alive whose data a mutation elsewhere has outdated. A page that changes shared
/// state marks the destinations it affects; the shell takes a mark when that destination is entered
/// again and rebuilds the page. Keys are `Destination` values; typed as [Enum] so the core layer never
/// imports the screens.
class StaleMarks {
  final Set<Enum> _marks = {};

  void mark(Iterable<Enum> destinations) => _marks.addAll(destinations);

  /// Whether [destination] was marked; the mark is consumed.
  bool take(Enum destination) => _marks.remove(destination);
}
