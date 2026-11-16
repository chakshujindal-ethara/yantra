/// App-wide constants that are NOT the API contract.
///
/// The backend origin and database are NOT here. They are resolved in
/// `lib/assessment/data/environment.dart` and surfaced by
/// `lib/assessment/data/api_client.dart` as `kApiBaseUrl` and `kApiDb`, because
/// the client owns them and duplicating them here would create a second source
/// of truth that can drift.
///
/// Normally nothing has to be passed: the app reads the host it is served from
/// and pairs itself with that environment's backend (`assessment.ethara.ai` ->
/// `projects.ethara.ai`, `-stage` -> `-stage`, localhost -> `localhost:8069`).
/// Override it for a host that is in no table - a preview deploy, an IP, or a
/// local build aimed at a remote backend:
///
///     flutter run -d chrome \
///       --dart-define=API_BASE_URL=https://projects-stage.ethara.ai
///
/// An unknown host with no override makes the app run on its bundled seed data,
/// which is what a design review wants and what the widget tests rely on.
library;

/// Product name shown in the header and the browser title.
///
/// The backing Odoo module is `assessments_be_v2`, and the back office calls
/// its app "Assessments v2". The old name pointed at `etp_assessment_pro`,
/// which is a DIFFERENT module still installed alongside it - so the console
/// named one product while talking to another.
const String kAppName = 'Assessment v2';
