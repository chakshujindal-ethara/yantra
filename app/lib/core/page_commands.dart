import 'package:flutter/widgets.dart';

/// An action a page offers the command palette ("New batch", "Refresh").
class PageCommand {
  const PageCommand(this.label, this.icon, this.run, {this.key});
  final String label;
  final IconData icon;
  final VoidCallback run;
  final Key? key;
}

/// The commands each mounted page registered, by the page's location. The shell keeps every branch alive,
/// so several pages are mounted at once; the palette shows only the ones of the location on screen.
class PageCommands extends ChangeNotifier {
  final Map<String, List<PageCommand>> _byLocation = {};

  void set(String location, List<PageCommand> commands) {
    _byLocation[location] = commands;
    notifyListeners();
  }

  void clear(String location, List<PageCommand> commands) {
    if (identical(_byLocation[location], commands)) {
      _byLocation.remove(location);
      notifyListeners();
    }
  }

  List<PageCommand> at(String location) => _byLocation[location] ?? const [];
}

class PageCommandsScope extends InheritedWidget {
  const PageCommandsScope({super.key, required this.commands, required super.child});
  final PageCommands commands;

  static PageCommands? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<PageCommandsScope>()?.commands;

  @override
  bool updateShouldNotify(PageCommandsScope oldWidget) => commands != oldWidget.commands;
}
