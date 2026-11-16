/// Safe Exam Browser, off the web: never inside it.
///
/// Exists to satisfy the conditional import in `api_client.dart` and the exam
/// screens, mirroring `url_bar_stub.dart`. The VM test suite runs against this
/// file, so no request carries a proof unless a test injects one.
library;

bool insideSeb() => false;

Map<String, String> sebProof() => const <String, String>{};

void navigateTo(String url) {}

void openInNewTab(String url) {}
