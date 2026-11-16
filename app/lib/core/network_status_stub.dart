/// Off the web there is no `navigator.onLine`: assume online and never change.
bool initialOnline() => true;

void watch(void Function(bool online) onChange) {}
