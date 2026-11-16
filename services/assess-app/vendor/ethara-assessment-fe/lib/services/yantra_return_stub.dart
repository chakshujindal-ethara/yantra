/// Where "Back to Yantra" goes, held across page loads.
///
/// Non-web builds (and the VM the tests run on) have no browser storage, so
/// this keeps the value in memory: enough for one run, which is all a test
/// needs. The web build keeps it in localStorage beside the session tokens.
library;

String? _value;

String? readYantraReturn() => _value;

void writeYantraReturn(String? url) => _value = url;
