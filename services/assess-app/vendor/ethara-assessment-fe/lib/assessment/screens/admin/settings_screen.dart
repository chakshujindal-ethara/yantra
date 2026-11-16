// Settings - HANDOVER §4.3.
//
// Models, storage, scoring limits, retention and spend caps: the four blocks
// this screen has always had, and the same order.
//
// EDITABLE NOW, where it used to be a read-only mirror. Every value here is a
// row in `ir.config_parameter` that `/api/v1/settings/update` allow-lists, so
// re-pointing a deployment no longer means opening the Odoo back office.
//
// The one credential that lives here is the Vertex SERVICE ACCOUNT, and it is
// a file rather than a field - kilobytes of JSON with a PEM block in it. The
// remaining secrets - the API key, the static bearer and the S3 pair - stay in
// Odoo, as the note under Storage has always said.
import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../state/app_store.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../../theme.dart';
import '../../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../../services/file_pick_web.dart';

class SettingsScreen extends StatelessWidget {
  final AppStore store;

  const SettingsScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (BuildContext context, _) => _body(context),
  );

  Widget _body(BuildContext context) => PageBody(
    children: <Widget>[
      PageHead(
        'Settings',
        sub: 'What the module is configured to do, and where to change it.',
      ),
      // The banner here used to say "The fallback model is not visible in the
      // source system." That stopped being true when the Odoo form gained the
      // field, and it was standing in for a Flutter-only value that is not
      // Flutter-only. A screen-level warning that is false teaches an operator
      // to discount the ones that are not.
      //
      // AND IT PROMISES ONLY WHAT THE FIELDS DO. "Clearing a box removes the
      // override" was written for the text boxes and read as a rule for all of
      // them: an emptied NUMBER is not posted at all - the route runs
      // `float("")` on an int key and refuses the whole panel for it - so the
      // stored value stays exactly where it was. What 0 means is not a rule
      // either: it restores the default on the scoring three and DISABLES the
      // control on the caps and the call ceiling, so it is stated under each
      // field rather than once up here.
      const Notice(
        tone: Tone.info,
        strong: 'Every box here overrides a module default.',
        text:
            'Clearing a text box removes the override and the default takes '
            'over again. A number cannot be cleared - an empty one keeps what '
            'is stored, and what 0 does is written under the box itself.',
      ),
      const SizedBox(height: 16),
      _EditPanel(store: store, title: 'Models', fields: _modelFields),
      const SizedBox(height: 16),
      // WHERE the models run and under whose identity, kept beside the service
      // account card that reports the same thing. The card shows what the
      // uploaded key resolved to; these two are what an operator overrides
      // when it resolved to the wrong place.
      _EditPanel(
        store: store,
        title: 'Vertex',
        fields: _vertexFields,
        footer: _ServiceAccountCard(store: store),
      ),
      const SizedBox(height: 16),
      _EditPanel(
        store: store,
        title: 'Scoring',
        fields: _scoringFields,
        // WHAT SCORING REALLY RUNS ON, after every fallback. The Scoring model
        // box above is an override and is often blank, so it cannot say this;
        // the server resolves it the way the grader does. Absent on a server
        // a deploy behind, and then nothing is claimed.
        header: _section(store, 'scoring')['resolved_model'] is Map
            ? _ScoringModelInUse(store: store)
            : null,
        footer: const Notice(
          tone: Tone.info,
          strong: 'A terminal error is never retried automatically.',
          text:
              'An attempt frozen on pending until a person acts is the '
              'point: an infrastructure failure must not be recorded as a '
              'candidate failure.',
        ),
      ),
      const SizedBox(height: 16),
      _EditPanel(
        store: store,
        title: 'Storage',
        note: 'The secret access key is set in Odoo and never sent here',
        fields: _storageFields,
        // Storage is REPORTED before it is edited. These used to be hardcoded
        // strings ("s3://etp-assessment-media", "25 MB") that stayed on screen
        // while the module had no bucket configured at all - a settings page
        // that reads confidently and is wrong is worse than one that admits
        // the gap.
        header: _storageConfigured(store)
            ? null
            : const Notice(
                tone: Tone.warn,
                strong: 'No object storage is configured.',
                text:
                    'Media stays inline in the database as base64. Uploads '
                    'need a bucket, an access key and a secret - the last '
                    'two are set in Odoo.',
              ),
      ),
      const SizedBox(height: 16),
      _GovernancePanel(store: store),
    ],
  );
}

/// A section of the settings payload, or an empty map when absent.
Map<Object?, Object?> _section(AppStore s, String section) {
  final Object? v = s.settings[section];
  return v is Map ? v : const <Object?, Object?>{};
}

bool _storageConfigured(AppStore s) =>
    _section(s, 'storage')['configured'] == true;

/// A nested value, addressed as `section.key` or `section.group.key`.
Object? _at(AppStore s, String path) {
  Object? node = s.settings;
  for (final String part in path.split('.')) {
    if (node is! Map) return null;
    node = node[part];
  }
  return node;
}

// ── The fields ────────────────────────────────────────────────────────────
//
// `wire` is the SHORT key `/api/v1/settings/update` allow-lists; `read` is
// where the same value comes back from `/api/v1/settings`, which groups by
// concern rather than by parameter name.

enum _Kind {
  /// Free text. Saving an EMPTY box clears the parameter, which is how an
  /// override is removed so the module's own default takes over again.
  text,

  /// A whole number, refused rather than coerced when it will not parse.
  integer,

  /// An on/off flag. Held in the same `TextEditingController` as everything
  /// else, as the literal 'true'/'false' the read route sends, so the seeding
  /// and dirty-tracking above stay one mechanism rather than two.
  boolean,
}

class _Spec {
  final String label;
  final String wire;
  final String read;
  final String help;
  final String hint;
  final _Kind kind;

  /// The exact values the server will store, or empty when anything goes.
  ///
  /// REFUSED AT THE DOOR RATHER THAN ON THE WIRE. `settings_update` validates
  /// the whole payload before its first write, so one unlistable value refuses
  /// every other field posted with it - eleven of them under Models - and all
  /// the operator gets back is a 422 naming one key. Checking here keeps the
  /// rest of the panel savable and names what would have been accepted.
  ///
  /// Both lists mirror `_SETTING_CHOICES` in write.py, and both matter for the
  /// same reason: each parameter backs an Odoo `fields.Selection`, and an
  /// unlisted value stored against one raises out of `default_get` - so a typo
  /// saved from here would take the Settings page down for every app in the
  /// database, not just this module's own form. The route refuses them too;
  /// refusing here is what keeps the rest of the panel savable.
  final List<String> choices;

  /// Where the value actually IN FORCE comes back, for a setting the server
  /// can lower below what is stored. Empty when what is stored is what runs.
  ///
  /// The box keeps showing the STORED value - it is posted back on every Save,
  /// and posting the lowered one would overwrite the setting with it.
  final String inUse;

  const _Spec(
    this.label, {
    required this.wire,
    required this.read,
    this.help = '',
    this.hint = '',
    this.kind = _Kind.text,
    this.choices = const <String>[],
    this.inUse = '',
  });
}

const List<_Spec> _modelFields = <_Spec>[
  // THE DEFAULT EVERY EMPTY OVERRIDE FALLS BACK TO, and the one model name the
  // screen could not show. An operator reading five blank overrides had no way
  // to see what was actually running.
  _Spec(
    'Default model',
    wire: 'vertex_model',
    read: 'models.default',
    help:
        'What runs wherever the override below it is blank. Changing this '
        'moves every lane that has not been set explicitly.',
    hint: 'gemini-3-pro-image',
  ),
  _Spec(
    'Generation model',
    wire: 'generation_model',
    read: 'models.generation',
    help: 'Reads the SOP with its images and authors the questions.',
    // D9: the hint used to read `gemini-3-pro`, which is not a name in this
    // module's catalogue. A hint is the only guidance an operator gets here,
    // so it has to be a value that resolves.
    hint: 'gemini-3.1-pro-preview',
  ),
  _Spec(
    'Scoring model',
    wire: 'scoring_model',
    read: 'models.scoring',
    help:
        'The judge that grades written answers. MUST be a text model, never '
        'the image model.',
    // No hint: prod stores blank and a model name here read as the stored
    // value (F2-02). "Scoring model in use" says what runs.
  ),
  _Spec(
    'Detection model',
    wire: 'detection_model',
    read: 'models.detection',
    help:
        'Finds the elements an image_label stimulus draws numbered boxes over.',
    // D9: this hint steered detection onto `gemini-3.1-pro-preview`, roughly
    // eight times the cost of the lite model the Odoo form suggests for the
    // same job, on every assessment anybody authored from this screen.
    hint: 'gemini-3.1-flash-lite',
  ),
  _Spec(
    'Flaw verification model',
    wire: 'verify_model',
    read: 'models.verify',
    help:
        'Reads a rendered image back to confirm the planted flaws landed. '
        'Blank falls through to the detection model.',
    hint: 'gemini-3.1-flash-lite',
  ),
  _Spec(
    'Utility model',
    wire: 'utility_model',
    read: 'models.utility',
    help:
        'The cheap lane: tag extraction, vocabulary consolidation, skill '
        'labelling. Blank falls through to the generation model.',
    hint: 'gemini-3.1-flash-lite',
  ),
  _Spec(
    'Image model',
    wire: 'image_model',
    read: 'models.image',
    help: 'Renders image_ab / image_prompt / image_label pictures.',
    hint: 'gemini-3-pro-image',
  ),
  _Spec(
    'Video model',
    wire: 'video_model',
    read: 'models.video',
    // D7: this help named `video_location` as the thing to get right while the
    // screen had no field for it, so the advice was unactionable from the app.
    // The field is two rows down now and the sentence points at it.
    help:
        'Clips are only generated when this AND Vertex credentials resolve. '
        'Veo is regional - set Video location below, not the Gemini global.',
    hint: 'veo-3.1-generate-001',
  ),
  _Spec(
    'Video location',
    wire: 'video_location',
    read: 'video.location',
    help:
        'Veo is served from named regions only. A 404 from the video lane is '
        'usually this, not the model name.',
    hint: 'us-central1',
  ),
  // THE ALLOWED SET BELONGS ON SCREEN, the way the bounds under Scoring do.
  // Veo takes these three lengths and no others, the module models it as a
  // Selection over the same tuple, and a fourth value refuses this whole panel
  // rather than just this box.
  _Spec(
    'Clip duration (seconds)',
    wire: 'video_default_duration_s',
    read: 'video.default_duration_s',
    choices: <String>['4', '6', '8'],
    help:
        'Length of a generated clip when a question does not ask for one. '
        '4, 6 or 8 - Veo accepts no other length.',
    hint: '6',
  ),
  _Spec(
    'Fallback model',
    wire: 'fallback_model',
    read: 'models.fallback',
    help: 'Taken silently when the primary refuses or times out.',
  ),
  _Spec(
    'Thinking level',
    wire: 'thinking_level',
    read: 'models.thinking_level',
    // Upper case, exactly as the resolver and the Odoo Selection spell them:
    // anything else is stored verbatim, ignored by every call, and then read
    // back onto this screen as though it were in force.
    choices: <String>['LOW', 'MEDIUM', 'HIGH'],
    help:
        'Gemini 3.x only. LOW, MEDIUM or HIGH. Blank lets the model decide, '
        'which is the right answer unless a lane is demonstrably underthinking.',
  ),
];

/// Where the models run and under whose identity.
const List<_Spec> _vertexFields = <_Spec>[
  // Shown but not settable before, on the service-account card. "The key is
  // for the wrong project" was diagnosable in the app and fixable only in
  // Odoo, which is the worst split of the two.
  _Spec(
    'Vertex project ID',
    wire: 'vertex_project_id',
    read: 'vertex.project_id',
    help:
        'The GCP project billed for every call. A service account upload sets '
        'this to its own project unless it is overridden here.',
    hint: 'my-gcp-project',
  ),
  _Spec(
    'Vertex location',
    wire: 'vertex_location',
    read: 'vertex.location',
    help:
        'Gemini 3.x is served from `global` only. A 404 that names a model '
        'that exists is usually this.',
    hint: 'global',
  ),
  // THE ONE BOUND NOTHING ELSE ENFORCES. The module's own range check on this
  // field is composed away by a same-named method in another installed addon,
  // so the Odoo form takes a negative without complaint. The API refuses it,
  // which makes this box the only place the limit is actually applied.
  _Spec(
    'Vertex calls per minute',
    wire: 'vertex_max_rpm',
    read: 'vertex.max_rpm',
    kind: _Kind.integer,
    help:
        'Ceiling on billable calls across every worker, counted from the spend '
        'ledger. 0 means no limit.',
  ),
];

const List<_Spec> _scoringFields = <_Spec>[
  _Spec(
    'Default pass threshold (%)',
    wire: 'default_pass_threshold',
    read: 'scoring.default_pass_threshold',
    kind: _Kind.integer,
    help:
        'Between 1 and 100. The pass threshold a new assessment starts with; '
        'changing it never touches existing assessments.',
  ),
  // THE BOUNDS BELONG IN THE HELP, NOT ONLY IN THE SERVER. Each of these is
  // range-checked on save, so a value outside it came back as a bare 422 toast
  // with no on-screen reason and no hint of what would have been accepted.
  _Spec(
    'Retry attempts',
    wire: 'llm_max_attempts',
    read: 'scoring.llm_max_attempts',
    kind: _Kind.integer,
    help:
        'Between 1 and 5. Applies to pending, queued and failed. A terminal '
        'error is excluded on purpose.',
  ),
  // D2 - THE WRONG KNOB WAS DESCRIBED. This said "answers graded per cron
  // tick", which is Tick limit below. An operator draining a slow queue raises
  // Batch size expecting throughput, gets none, and walks into the truncated
  // scoring responses that a large batch causes.
  _Spec(
    'Batch size',
    wire: 'scoring_batch_size',
    read: 'scoring.batch_size',
    kind: _Kind.integer,
    help:
        'Answers packed into ONE Vertex call, between 1 and 32. This does not '
        'raise throughput - lower it if scoring responses come back truncated.',
  ),
  // D3 - "per shard" was dropped, so the throughput arithmetic an operator
  // does from this screen is wrong by the shard count.
  //
  // AND THE UNIT IS CANDIDATES, NOT ANSWERS. `_scoring_shard_evaluators` caps
  // the evaluator rows one shard claims in a tick, and one evaluator is one
  // candidate carrying every subjective answer on their paper - the module's
  // own field is called "Scoring Candidates per Tick". Saying answers here
  // under-reports the real answer rate by the questions-per-paper factor, and
  // puts Batch size directly above it in what looks like the same unit at a
  // smaller scale, which is the D2 defect again one row down.
  _Spec(
    'Tick limit',
    wire: 'scoring_tick_limit',
    read: 'scoring.tick_limit',
    kind: _Kind.integer,
    help:
        'Candidates one shard drains per minute, each carrying a whole paper. '
        'This is the throughput knob: 20 per shard per minute is about 1,200 '
        'candidates an hour per shard.',
  ),
  // D4 - the ceiling is four crons; a higher number is accepted by the field
  // and then ignored by the module, which is indistinguishable from broken.
  _Spec(
    'Shards',
    wire: 'scoring_shards',
    read: 'scoring.shards',
    kind: _Kind.integer,
    help:
        'Parallel scoring workers, between 1 and 4. There are four crons, so a '
        'higher number is ignored rather than honoured.',
  ),
  _Spec(
    'Parallel calls',
    wire: 'scoring_parallel_calls',
    read: 'scoring.parallel_calls',
    // Each call in flight holds about two DB connections, so the module
    // lowers this at runtime to fit half of Odoo's pool across every lane.
    inUse: 'scoring.parallel_calls_effective',
    kind: _Kind.integer,
    help:
        'Judge calls each shard keeps in flight, between 1 and 8. Marks are '
        'still saved one candidate at a time; 1 grades serially. Raise Tick '
        'limit with it, to about five times this.',
  ),
];

const List<_Spec> _storageFields = <_Spec>[
  _Spec(
    'Image storage bucket',
    wire: 's3_bucket',
    read: 'storage.s3_bucket',
    help:
        'The private bucket rendered media is written to. Nothing is served '
        'from it directly - a URL is presigned per request.',
    hint: 'ethara-etp-assessment',
  ),
  _Spec(
    'Region',
    wire: 's3_region',
    read: 'storage.s3_region',
    hint: 'ap-south-1',
  ),
  // D8: the panel note claimed credentials never reach this app, which was
  // standing in for a field nobody had written. The key ID travels in both
  // directions already and the read route argues, correctly, that it is an
  // identifier and not a secret. The SECRET stays in Odoo; this does not.
  _Spec(
    'Access key ID',
    wire: 's3_access_key_id',
    read: 'storage.s3_access_key_id',
    help:
        'The identifier half of the credential. The secret half is set in '
        'Odoo and is never sent here.',
    hint: 'AKIA...',
  ),
  _Spec(
    'Key prefix',
    wire: 's3_folder',
    read: 'storage.s3_folder',
    help:
        'Every object lands under this, so one bucket can hold more than one '
        'environment.',
    hint: 'assessments_be',
  ),
  _Spec(
    'CDN base URL',
    wire: 's3_cdn_url',
    read: 'storage.s3_cdn_url',
    help: 'Optional. Blank keeps the bucket private and presigns instead.',
    hint: 'https://cdn.example.com',
  ),
  _Spec(
    'Upload retries',
    wire: 's3_max_retries',
    read: 'storage.s3_max_retries',
    kind: _Kind.integer,
    help: 'Attempts before a render is marked failed.',
  ),
  _Spec(
    'Redirect media to S3',
    wire: 'media_redirect_to_s3',
    read: 'storage.media_redirect_to_s3',
    kind: _Kind.boolean,
    help:
        'On, a media request is answered with a 302 to a presigned S3 URL. '
        'Off, Odoo streams the bytes itself.',
  ),
];

// ── The editable panel ────────────────────────────────────────────────────

/// One block of settings, rendered from [fields] and saved as a unit.
///
/// ONE widget rather than a hand-written panel per block, because the blocks
/// differ only in their rows: the seeding, the dirty tracking, the validation
/// and the save are identical, and three copies of them is three places for
/// the "Save reports success and the value never moves" bug to come back.
/// That bug was real once already - see [_GovernancePanelState] on why the
/// wire key has to be the SHORT one.
class _EditPanel extends StatefulWidget {
  final AppStore store;
  final String title;
  final String? note;
  final List<_Spec> fields;

  /// Drawn above the fields - a warning that changes what they mean.
  final Widget? header;

  /// Drawn below them, above the Save row.
  final Widget? footer;

  const _EditPanel({
    required this.store,
    required this.title,
    required this.fields,
    this.note,
    this.header,
    this.footer,
  });

  @override
  State<_EditPanel> createState() => _EditPanelState();
}

class _EditPanelState extends State<_EditPanel> {
  final Map<String, TextEditingController> _ctl =
      <String, TextEditingController>{};

  /// What the server last said, per field, so a value that arrived from a
  /// refresh can be told apart from one somebody typed.
  final Map<String, String> _seeded = <String, String>{};

  bool _dirty = false;

  /// Seeded from the server, and re-seeded ONLY for a field nobody has edited.
  ///
  /// Rebuilding every controller from the store on each build would wipe what
  /// is being typed the moment anything calls `notifyListeners` - and the
  /// store notifies on every background refresh, which runs while a form is
  /// open. Never re-seeding is wrong the other way: uploading a service
  /// account changes values on the server, and a field showing one has to
  /// follow. So an untouched field tracks the server and a touched one holds.
  TextEditingController _c(_Spec f) {
    final Object? v = _at(widget.store, f.read);
    final String fresh = v == null ? '' : '$v';
    final TextEditingController c = _ctl.putIfAbsent(f.wire, () {
      _seeded[f.wire] = fresh;
      return TextEditingController(text: fresh);
    });
    if (_seeded[f.wire] != fresh && c.text == _seeded[f.wire]) {
      c.text = fresh;
      _seeded[f.wire] = fresh;
    }
    return c;
  }

  Future<void> _save() async {
    final Map<String, Object> values = <String, Object>{};
    for (final _Spec f in widget.fields) {
      final String raw = _c(f).text.trim();
      // A FIELD THE SERVER DID NOT REPORT IS NEVER WRITTEN BACK.
      //
      // The two halves of a setting ship in one module and arrive in a browser
      // as two: this bundle can be live while the backend it talks to is a
      // restart behind. `models.thinking_level` is exactly that shape - the
      // write route has accepted it all along, the read route only started
      // sending it in this release - so an older server answers without the
      // key, the box seeds blank from nothing, and posting that blank back
      // CLEARS a configured value nobody on this screen was ever shown. An
      // absent key and a reported-empty one are different facts and only the
      // second one means "no override is set". A box somebody typed in is
      // still posted: holding the seeded value is what marks it untouched.
      if (raw == _seeded[f.wire] && _at(widget.store, f.read) == null) {
        continue;
      }
      // Refused here rather than as a 422 that discards the rest of the panel
      // - see [_Spec.choices]. Blank is exempt for the same reason the route
      // exempts it: an empty string is how an override is removed.
      if (f.choices.isNotEmpty && raw.isNotEmpty && !f.choices.contains(raw)) {
        widget.store.toaster.bad(
          '${f.label} must be one of ${f.choices.join(', ')}',
        );
        return;
      }
      switch (f.kind) {
        case _Kind.integer:
          // AN EMPTY NUMBER BOX LEAVES THE STORED VALUE ALONE, and the banner
          // at the top of the screen says so. There is nothing to send: the
          // route runs `float("")` on an int key and refuses the whole panel
          // for it, and 0 is not a synonym for "unset" - it restores the
          // default on the scoring three and DISABLES the ceiling on
          // `vertex_max_rpm`. The re-seed after the save puts the stored value
          // back in the box, so the blank does not outlive the Save.
          if (raw.isEmpty) continue;
          final int? n = int.tryParse(raw);
          if (n == null || n < 0) {
            widget.store.toaster.bad(
              '${f.label} must be a whole number, 0 or more',
            );
            return;
          }
          values[f.wire] = n;
        case _Kind.boolean:
          // A REAL JSON boolean, not the string. `ir.config_parameter` stores
          // text and every falsy-looking string it can hold - "0", "false",
          // "" - is truthy to a plain bool(), so a flag posted as text is one
          // careless read away from being permanently on. The route refuses
          // anything that is not a true boolean for the same reason.
          values[f.wire] = raw == 'true';
        case _Kind.text:
          // Sent even when empty: blank is how an override is REMOVED so the
          // module falls back to its own default.
          values[f.wire] = raw;
      }
    }
    if (values.isEmpty) return;
    await widget.store.saveSettings(
      values,
      labels: <String, String>{
        for (final _Spec f in widget.fields) f.wire: f.label,
      },
    );
    if (!mounted) return;
    // SAVED IS UNTOUCHED AGAIN, which is what lets the boxes follow the server
    // one more time.
    //
    // `_c` re-seeds only a field whose controller still holds what the server
    // last said. That is right while a form is being filled in and wrong the
    // moment it has been submitted: a field that was ever typed into stayed
    // pinned for the life of the panel and could never show a stored value
    // again. What comes back is not always what was posted - `scoring` reports
    // the RESOLVED batch size and attempt count, so a stored 0 reads back as 8
    // and 3 - and an emptied number box is not posted at all. Both leave the
    // screen asserting a value that is not in force. Re-marking every
    // controller as seeded lets the re-read `saveSettings` has just done fill
    // them in, including after a refusal, where what is stored is the value
    // the operator started from.
    for (final _Spec f in widget.fields) {
      final TextEditingController? c = _ctl[f.wire];
      if (c != null) _seeded[f.wire] = c.text;
    }
    setState(() => _dirty = false);
  }

  /// [field], with what really runs under it when that is not what is stored.
  ///
  /// ONLY WHEN THEY DIFFER. A line repeating the box above it on every normal
  /// deployment teaches the eye to skip it; this one appears when the module
  /// has lowered the setting, which is the one time it has something to say.
  Widget _withInUse(BuildContext context, _Spec f, Widget field) {
    final Object? running = f.inUse.isEmpty ? null : _at(widget.store, f.inUse);
    if (running == null || '$running' == '${_at(widget.store, f.read)}') {
      return field;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        field,
        const SizedBox(height: 4),
        Text(
          'In use per lane: $running - lowered to fit the database '
          'connection pool.',
          style: context.type.tiny.copyWith(
            height: 1.45,
            color: context.tokens.warnText,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    for (final TextEditingController c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Panel(
    title: widget.title,
    note: widget.note ?? 'Editable',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.header != null) ...<Widget>[
          widget.header!,
          const SizedBox(height: 14),
        ],
        FieldGrid(<Widget>[
          for (final _Spec f in widget.fields)
            _withInUse(
              context,
              f,
              _SettingField(
                spec: f,
                controller: _c(f),
                onChanged: () {
                  if (!_dirty) setState(() => _dirty = true);
                },
              ),
            ),
        ]),
        if (widget.footer != null) ...<Widget>[
          const SizedBox(height: 14),
          widget.footer!,
        ],
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            const Spacer(),
            Btn.primary(
              'Save',
              busy: widget.store.isBusy('settings'),
              onPressed: _dirty ? _save : null,
            ),
          ],
        ),
      ],
    ),
  );
}

/// One row of [_EditPanel].
class _SettingField extends StatelessWidget {
  final _Spec spec;
  final TextEditingController controller;
  final VoidCallback onChanged;

  const _SettingField({
    required this.spec,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Field(
    label: spec.label,
    help: spec.help,
    child: spec.kind == _Kind.boolean
        // THE SWITCH FOLLOWS ITS OWN CONTROLLER, not the panel's rebuilds.
        //
        // `Switcher` is fully controlled: it draws the `value` it was last
        // built with and answers a tap with `!value`. Nothing repainted it
        // except the panel, through `onChanged` - and that callback stops
        // calling `setState` once the panel is already dirty. So a toggle
        // touched after any other edit in the same panel wrote 'false' into
        // the controller, went on drawing ON, and sent 'false' again on every
        // further tap: the screen showed the opposite of what Save would post,
        // which is worse than having no toggle at all. A TextEditingController
        // IS a ValueListenable, so listening to it makes the switch track its
        // own value whatever the panel does.
        ? ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (BuildContext context, TextEditingValue v, _) => Align(
              alignment: Alignment.centerLeft,
              child: Switcher(
                value: v.text == 'true',
                onChanged: (bool on) {
                  controller.text = on ? 'true' : 'false';
                  onChanged();
                },
              ),
            ),
          )
        : TextField(
            controller: controller,
            keyboardType: spec.kind == _Kind.integer
                ? TextInputType.number
                : TextInputType.text,
            style: context.type.body.copyWith(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              // A typical value, shown as a HINT rather than as text: an empty field
              // here really is empty, and printing the module's default as a value
              // would make "inherited" indistinguishable from "set to this".
              hintText: spec.hint.isEmpty ? null : spec.hint,
            ),
            onChanged: (_) => onChanged(),
          ),
  );
}

/// The model scoring resolves to after every fallback, read-only, and a
/// warning when the module's catalog cannot price it or does not know its
/// limits - the two things a scoring-model swap has to check first.
class _ScoringModelInUse extends StatelessWidget {
  final AppStore store;

  const _ScoringModelInUse({required this.store});

  @override
  Widget build(BuildContext context) {
    final Map<Object?, Object?> m =
        _section(store, 'scoring')['resolved_model']! as Map<Object?, Object?>;
    final String model = (m['model'] ?? '').toString();
    // `== false`, not `!= true`: a key this server does not send is not a
    // missing price, and warning about it would be a false alarm.
    final bool noPrice = m['price_known'] == false;
    final bool noCaps = m['capabilities_known'] == false;
    final String name = model.isEmpty ? 'this model' : model;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Fact(
          label: 'Scoring model in use',
          value: model.isEmpty ? 'None resolved' : model,
        ),
        if (noPrice || noCaps) ...<Widget>[
          const SizedBox(height: 10),
          Notice(
            tone: Tone.warn,
            strong: noPrice && noCaps
                ? 'No price or capability data for $name.'
                : noPrice
                ? 'No price data for $name.'
                : 'No capability data for $name.',
            text: <String>[
              if (noPrice)
                'Its spend is estimated at the catalog default rate, not its '
                    'own, so the ledger and the spend caps are approximate.',
              if (noCaps)
                'Its output limit is unknown, so reply budgets are sent '
                    'without being capped to it.',
              'Pick a model the module knows, or have this one added to its '
                  'catalog.',
            ].join(' '),
          ),
        ],
      ],
    );
  }
}

/// Upload, replace or remove the Vertex service-account JSON.
///
/// Handled as a FILE, and write-only: the key is stored encrypted server-side
/// and cannot be read back by anything, including this screen. What comes back
/// is the identity inside it - the GCP project and the account it signs as -
/// which is what an operator staring at a 403 needs.
///
/// The server validates before it stores, so a JSON that is not a service
/// account (an OAuth client, a downloaded API key) is refused by name here
/// rather than failing an hour later as an opaque 401.
class _ServiceAccountCard extends StatelessWidget {
  final AppStore store;

  const _ServiceAccountCard({required this.store});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool set = _at(store, 'vertex.service_account.set') == true;
    final String filename =
        (_at(store, 'vertex.service_account.filename') ?? '').toString();
    final String who = (_at(store, 'vertex.service_account.client_email') ?? '')
        .toString();
    final String project = (_at(store, 'vertex.project_id') ?? '').toString();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: Radii.card,
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'Service account JSON',
                style: context.type.body.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 9),
              if (set)
                const StatusBadge('Configured', Tone.ok)
              else
                const StatusBadge('Not set', Tone.inert),
              const Spacer(),
              if (set) ...<Widget>[
                IconBtn(
                  Icons.delete_outline,
                  tooltip: 'Remove',
                  onPressed: store.isBusy('settings')
                      ? null
                      : () => store.uploadServiceAccount(const <int>[], ''),
                ),
                const SizedBox(width: 4),
              ],
              Btn(
                set ? 'Replace' : 'Upload',
                icon: Icons.folder_open,
                size: BtnSize.sm,
                busy: store.isBusy('settings'),
                onPressed: () async {
                  final PickedFile? f = await pickFile(
                    accept: '.json,application/json',
                  );
                  if (f == null) return;
                  await store.uploadServiceAccount(f.bytes, f.name);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (set)
            // WHAT THE FILE SAID, so an upload is visibly an act with a result
            // rather than a toast that disappears.
            Wrap(
              spacing: 18,
              runSpacing: 6,
              children: <Widget>[
                if (project.isNotEmpty) _Fact(label: 'Project', value: project),
                if (who.isNotEmpty) _Fact(label: 'Signing as', value: who),
                if (filename.isNotEmpty) _Fact(label: 'File', value: filename),
              ],
            )
          else
            Text(
              'Upload the key from IAM > Service Accounts > Keys. The module '
              'signs a JWT with it and refreshes its own hourly bearer, and '
              'takes the GCP project from the file.',
              style: context.type.tiny,
            ),
        ],
      ),
    );
  }
}

/// One label/value pair from the uploaded key.
class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(label.toUpperCase(), style: context.type.fieldLabel),
      const SizedBox(height: 2),
      Text(value, style: context.type.body.copyWith(fontSize: 12.5)),
    ],
  );
}

/// The four numbers that bound spend and retention.
///
/// Its own panel rather than another [_EditPanel]: these are the settings
/// whose validation is about MEANING rather than type - a cap of 0 is "no
/// cap", not "no spend" - and the copy under each one is doing as much work as
/// the field itself.
class _GovernancePanel extends StatefulWidget {
  final AppStore store;

  const _GovernancePanel({required this.store});

  @override
  State<_GovernancePanel> createState() => _GovernancePanelState();
}

class _GovernancePanelState extends State<_GovernancePanel> {
  /// SHORT keys on the wire, not `assessments_be_v2.`-qualified ones.
  ///
  /// `settings_update` walks its own allow-list and reads
  /// `arg(key.split(".", 1)[1])`, so it looks for `daily_llm_cap_usd`. Sending
  /// the qualified name matched nothing - and because an unread key is silence
  /// rather than a 400, the route answered ok with `updated: {}`: the Save
  /// button reported success and the value never moved. Verified on the wire.
  static const List<String> _keys = <String>[
    'daily_llm_cap_usd',
    'per_evaluator_llm_cap_usd',
    'pii_retention_days',
    'score_outlier_sigma',
  ];

  /// What each key is called on screen: a refusal names the field the
  /// operator sees, never the wire key (RT-3).
  static const Map<String, String> _labels = <String, String>{
    'daily_llm_cap_usd': 'Daily LLM cap (USD)',
    'per_evaluator_llm_cap_usd': 'Per-candidate LLM cap (USD)',
    'pii_retention_days': 'PII retention (days)',
    'score_outlier_sigma': 'Score outlier threshold (sigma)',
  };

  final Map<String, TextEditingController> _ctl =
      <String, TextEditingController>{};
  bool _dirty = false;

  /// Seeded from the server ONCE, not on every build: rebuilding the
  /// controllers from the store would wipe what is being typed on the first
  /// notifyListeners - and the store notifies on every background refresh.
  TextEditingController _c(String field) => _ctl.putIfAbsent(field, () {
    final Object? v = _section(widget.store, 'governance')[field];
    return TextEditingController(text: v is num ? _plain(v) : '');
  });

  static String _plain(num v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

  Future<void> _save() async {
    final Map<String, Object> values = <String, Object>{};
    for (final String key in _keys) {
      final String raw = _c(key).text.trim();
      if (raw.isEmpty) continue;
      final num? n = num.tryParse(raw);
      // A malformed number is refused rather than coerced: sending 0 for
      // "abc" would silently REMOVE a spend cap.
      if (n == null || n < 0) {
        widget.store.toaster.bad('${_labels[key]} must be a number, 0 or more');
        return;
      }
      values[key] = n;
    }
    if (values.isEmpty) return;
    await widget.store.saveSettings(values, labels: _labels);
    if (mounted) setState(() => _dirty = false);
  }

  @override
  void dispose() {
    for (final TextEditingController c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Panel(
    title: 'Retention and Spend',
    note: 'Editable',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FieldGrid(<Widget>[
          _NumField(
            label: _labels['daily_llm_cap_usd']!,
            controller: _c('daily_llm_cap_usd'),
            help:
                'Spend across every operation in a single day. 0 means no '
                'cap, which is not the same as unset.',
            onChanged: () => setState(() => _dirty = true),
          ),
          _NumField(
            label: _labels['per_evaluator_llm_cap_usd']!,
            controller: _c('per_evaluator_llm_cap_usd'),
            help: 'Bounds what grading one attempt may cost.',
            onChanged: () => setState(() => _dirty = true),
          ),
          _NumField(
            label: _labels['pii_retention_days']!,
            controller: _c('pii_retention_days'),
            help: '0 keeps candidate data indefinitely.',
            onChanged: () => setState(() => _dirty = true),
          ),
          _NumField(
            label: _labels['score_outlier_sigma']!,
            controller: _c('score_outlier_sigma'),
            help:
                'Standard deviations from the cohort mean before a score is '
                'flagged for a human look. 0 disables the check.',
            onChanged: () => setState(() => _dirty = true),
          ),
        ]),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            const Spacer(),
            Btn.primary(
              'Save',
              busy: widget.store.isBusy('settings'),
              onPressed: _dirty ? _save : null,
            ),
          ],
        ),
      ],
    ),
  );
}

class _NumField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String help;
  final VoidCallback onChanged;

  const _NumField({
    required this.label,
    required this.controller,
    required this.help,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Field(
    label: label,
    help: help,
    child: TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: context.type.body.copyWith(fontSize: 13),
      decoration: const InputDecoration(isDense: true),
      onChanged: (_) => onChanged(),
    ),
  );
}
