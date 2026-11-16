import 'format.dart';

/// Errors raised by the gateway and identity layers. Screens turn these into one line of text.
sealed class AppException implements Exception {
  const AppException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The gateway answered with an error envelope `{code, message, request_id, ...}`.
class ApiException extends AppException {
  const ApiException({
    required this.status,
    required this.code,
    required String message,
    this.requestId = '',
    this.retryAfter,
    this.context = const {},
  }) : super(message);

  final int status;
  final String code;
  final String requestId;

  /// The envelope's `context` object: ids and figures the message talks about (`sitting_id`, ...).
  final Map<String, dynamic> context;

  /// Seconds to wait before retrying (`Retry-After`), when the gateway sent one.
  final Duration? retryAfter;

  bool get isRateLimited => status == 429;
  bool get isUnavailable => status == 503;
  bool get isConflict => status == 409;
}

/// Object storage refused a transfer the app made itself (a presigned upload or download): there is no
/// gateway envelope, and [message] is already written for people.
class StorageException extends ApiException {
  const StorageException({required super.status, required super.code, required super.message});
}

/// The session cannot be repaired (no refresh token, or refresh refused): the worker must log in again.
class AuthRequiredException extends AppException {
  const AuthRequiredException([super.message = 'Please sign in again']);
}

/// Keycloak refused the credentials or the refresh token.
class LoginFailedException extends AppException {
  const LoginFailedException(super.message);
}

/// The network or the server could not be reached. [offline] when the browser itself reports no network.
class TransportException extends AppException {
  const TransportException(super.message, {this.offline = false});
  final bool offline;
}

/// A 200 whose body is not the shape the screen asked for (HTML from a proxy, a list for an object):
/// surfaced as an error instead of being read as empty data. [excerpt] is the start of the body, for logs.
class ShapeError extends AppException {
  ShapeError(this.expected, String body) : excerpt = body.length > 80 ? body.substring(0, 80) : body, super('Expected $expected');
  final String expected;
  final String excerpt;

  @override
  String toString() => 'ShapeError: expected $expected, got "$excerpt"';
}

/// Plain copy for the gateway's known error codes. The server's own message is written for logs and
/// operators; a person sees one of these, or the generic fallback with a reference to quote.
const errorCopy = <String, String>{
  'claim_not_live': 'This claim is no longer live: it was submitted, released or it expired.',
  'claim_expired': 'This claim expired before you submitted. Claim another unit.',
  'one_live_claim': 'You already hold a claim. Finish or release it first.',
  'sitting_expired': 'Time ran out on this sitting, so it counts as a failed attempt.',
  'sitting_closed': 'This sitting is already closed.',
  'batch_cancelled': 'This batch was cancelled, so it no longer takes work.',
  'batch_paused': 'This batch is paused for now. Try again later.',
  'already_applied': 'You have already applied to this pool.',
  'listing_full': 'This pool filled up before your application landed.',
  'offer_expired': 'This offer expired before you answered; expired counts as declined.',
  'policy_outdated': 'This text was updated while you were reading it. Read the new version and accept again.',
  'name_mismatch': 'The account name must match your legal name exactly as you entered it in Profile.',
  'account_in_use': 'This bank account is already registered to another worker. One account per person.',
  'validation_limit': 'The bank has been asked to check accounts three times today. Try again tomorrow.',
  'review_expired': 'The hold on this task ran out, so it went back to the queue.',
  'gate_required': 'This work needs a certification you do not hold yet.',
  'sensitive_cleared_required': 'This work needs sensitive-data clearance first.',
  'one_live_review': 'You still hold a review task. Finish it first.',
  'not_reconciled': 'Statements are released once this window is reconciled.',
  'batch_held': 'This batch is still held at the delivery gate.',
  'storage_unavailable': 'File storage is not answering right now. Try again in a minute.',
  'request_in_flight': 'Your last request is still being processed. Wait a moment and try again.',
  'idempotency_mismatch': 'This changed since your last try. Try again.',
  'erasure_pending': 'You already asked for your data to be deleted; that request is being handled.',
  'erasure_done': 'Your personal data has already been deleted.',
  'wrong_code': 'That code is not the one we sent.',
  'nothing_to_verify': 'No address is waiting for a code. Enter your email again to get one.',
  'code_expired': 'This code expired; codes last 15 minutes. Send a new code.',
  'too_many_attempts': 'Too many tries. Start again with a fresh request.',
  'same_person': 'You cannot do this for yourself or approve your own proposal. Ask a colleague.',
  'worker_held': 'This worker is on a payout hold. Lift the hold before sending the payout again.',
  'rail_mismatch': 'This line was queued on another payment rail, so it cannot go out on this one.',
  'not_awaiting_confirmation': 'This bank account no longer needs confirming. Refresh to see its state.',
  'window_over_cap': 'This window is above the per-window payout cap.',
  'line_not_failed': 'This line is no longer failed. Refresh to see where it is.',
  'account_unverified': 'This worker has no verified bank account yet.',
  'self_action': 'You cannot do this on your own record. Ask a colleague.',
  'unit_not_assigned': 'This unit is no longer waiting for one worker. Refresh to see where it is.',
  'assignment_required': 'This batch hands every unit to a named worker, so it has no pool to return the unit to.',
  'batch_purged': "This delivery was purged under the project's retention policy.",
  'consent_withdrawn': "You withdrew consent, so you can't take new work. Give consent again in Profile → Your data.",
  'paper_author': "You wrote or published this paper, so you can't sit it.",
  'already_certified': 'You already hold this certification. There is nothing more to sit.',
  'attempts_exhausted': 'You have used every attempt on this paper. Ask ops if you believe that is wrong.',
  'result_pending': 'Your last attempt is still being marked. You can sit again once its result is out.',
  'engine_refused': 'The assessment could not be started.',
  'engine_unavailable': 'The assessment service is not answering right now. Try again in a minute.',
  'paper_retired': 'This paper has been replaced. Open the pool again to find the current one.',
  'paper_not_published': 'This paper is not open for sitting yet.',
  'launch_blocked': 'Assessment v2 cannot open this exam yet.',
  'nothing_to_release': 'Nothing is waiting for release. Sync now to read the latest results.',
  'assessment_not_draft': 'That assessment has already been launched in Assessment v2. Link a draft one.',
  'assessment_in_use': 'Another paper already uses that assessment. Link a different one.',
  'already_published': 'This paper is already published.',
  'invalid_next': 'That Assessment admin page is not one Yantra can open.',
  'portal_account': 'Your email is tied to an old portal account in the assessment system. Ask ops to merge it.',
  'identity_conflict': 'Your email is already linked to another person in the assessment system. Ask ops to fix it.',
  'forbidden': 'You do not have access to this.',
  'not_found': 'This is no longer there. Refresh and try again.',
};

/// True for ops, finance and admin: their errors also carry the server's message on a smaller
/// "Details" line ([splitDetails]). The app sets it from the session's roles.
bool showErrorDetails = false;

const _generic = 'Something went wrong. Try again; if it keeps happening, report it.';
const _detailsMark = '\nDetails: ';

/// One line a worker can act on, for any error a screen may catch. For staff ([showErrorDetails]) a
/// gateway error adds the server's message after a newline; [splitDetails] separates the two.
String describeError(Object error) {
  return switch (error) {
    StorageException(:final message) => message,
    ApiException(isRateLimited: true, :final retryAfter) => 'Too many requests. Wait ${_seconds(retryAfter, 60)} and try again.',
    ApiException(isUnavailable: true, :final retryAfter) => 'Service is away. Retry in ${_seconds(retryAfter, 2)}.',
    final ApiException e => _withDetails(_apiCopy(e), e.message),
    TransportException(offline: true) => "You're offline. Check your connection and try again.",
    TransportException() => "Can't reach Yantra. Check your connection and try again.",
    ShapeError() => 'Yantra answered with something unexpected. Try again; if it keeps happening, report it.',
    AppException(:final message) => message,
    _ => 'Something went wrong. Please try again.',
  };
}

/// The plain line and, when present, the details line of a [describeError] answer.
(String, String?) splitDetails(String line) {
  final at = line.indexOf(_detailsMark);
  return at < 0 ? (line, null) : (line.substring(0, at), line.substring(at + _detailsMark.length));
}

/// A purged batch's copy, with the day retention emptied it when known.
String purgedCopy(DateTime? at) =>
    at == null ? errorCopy['batch_purged']! : "This delivery was purged under the project's retention policy on ${shortDate(at)}.";

String _apiCopy(ApiException e) {
  switch (e.code) {
    case 'batch_purged':
      return purgedCopy(DateTime.tryParse('${e.context['purged_at'] ?? ''}'));
    case 'engine_refused':
      final reason = '${e.context['engine_code'] ?? e.context['reason'] ?? ''}'.trim();
      return reason.isEmpty ? errorCopy['engine_refused']! : '${errorCopy['engine_refused']} ${_sentence(reason)}';
    case 'wrong_code':
      final left = e.context['attempts_left'];
      if (left is int) return '${errorCopy['wrong_code']} $left ${left == 1 ? 'try' : 'tries'} left.';
  }
  final known = errorCopy[e.code];
  if (known != null) return known;
  if (e.code == 'invalid' || e.status == 422) return _invalidCopy(e);
  return e.requestId.isEmpty ? _generic : '$_generic Reference: ${e.requestId}';
}

/// A refused answer names its fields (`context.fields`, else the field in the validator's message);
/// any other refused form gets one plain sentence.
String _invalidCopy(ApiException e) {
  const lead = "Some answers don't match what this unit asks for";
  final fields = e.context['fields'];
  if (fields is List && fields.isNotEmpty) return '$lead: ${fields.join(', ')}';
  if (!e.message.startsWith('answer:')) return "Some of what you entered isn't valid. Check the form and try again.";
  final rest = e.message.substring('answer:'.length).trim();
  final field =
      RegExp(r"^([A-Za-z0-9_/.-]+): ").firstMatch(rest)?.group(1) ??
      RegExp(r"^'([^']+)' is a required property").firstMatch(rest)?.group(1);
  return field == null ? '$lead.' : '$lead: $field';
}

/// A reason code or phrase from another system as a sentence: `nothing_assigned` → "Nothing assigned."
String _sentence(String reason) {
  final words = reason.replaceAll('_', ' ').trim();
  final cap = words[0].toUpperCase() + words.substring(1);
  return cap.endsWith('.') ? cap : '$cap.';
}

String _withDetails(String copy, String message) => showErrorDetails && message.isNotEmpty ? '$copy$_detailsMark$message' : copy;

/// A screen's own sentence for [error], with the server's message as details for staff (see [describeError]).
String withDetails(String copy, ApiException error) => _withDetails(copy, error.message);

String _seconds(Duration? d, int fallback) => '${d?.inSeconds ?? fallback}s';

/// Whether a retry of the same action may reuse its idempotency key. The gateway stores every answer
/// below 500 except 408 and 429 and replays it for the same key, so after any other 4xx the next attempt
/// is a new action; after a transport failure, a 5xx, a 408 or a 429 the request may not have landed and
/// the same key is exactly what makes the retry safe.
bool retryKeepsKey(Object error) => switch (error) {
  TransportException() => true,
  ApiException(:final status) => status >= 500 || status == 429 || status == 408,
  _ => false,
};
