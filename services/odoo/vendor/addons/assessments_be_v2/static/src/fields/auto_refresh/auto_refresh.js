import { registry } from "@web/core/registry";
import {
    Component, onWillStart, onWillUnmount, onWillUpdateProps, useState,
} from "@odoo/owl";
import { standardFieldProps } from "@web/views/fields/standard_field_props";
import { _t } from "@web/core/l10n/translation";

/**
 * Auto-refresh badge for async, cron-driven work: SOP generation, tag
 * extraction and subjective grading (the assessment's scoring phase and each
 * candidate's `llm_state`). The queue buttons return at once and a cron does
 * the work, so without this the open form shows a stale state until the admin
 * reloads by hand.
 *
 * It renders the state as a badge and, while the state is BUSY, polls the
 * current record: every POLL_MS, backing off to MAX_POLL_MS while nothing
 * changes. When the server value leaves the busy set it reloads the form - or,
 * if the form has unsaved edits, offers the reload instead. It stops polling
 * once the work settles or the component unmounts.
 *
 * Usage in a view:
 *   <field name="sop_gen_state" widget="be_auto_refresh"/>
 *   <field name="llm_state" widget="be_auto_refresh"
 *          options="{'busy_if': 'scoring_requested'}"/>
 */
// `scoring` is the state the drainer writes just BEFORE the Vertex call - the
// moment a candidate is genuinely in flight - so it must poll. `stopping` is
// the assessment phase while a kill is mid-handshake; it settles on its own.
//
// `stalled` is DELIBERATELY ABSENT: a run polling on `queued` reads `stalled`,
// finds it outside this set, and reloads the record once, which puts the
// form's stalled-grader alert on screen. It is still watched, at MAX_POLL_MS,
// because it can now clear on its own (a lane lock released, a 429 burst
// over), and the open form should recover without a reload.
const DEFAULT_BUSY = [
    "queued", "generating", "finalizing", "extracting", "pending",
    "scoring", "stopping",
];
const POLL_MS = 3000;
// BACKOFF WHILE NOTHING CHANGES. A run can sit in one busy state for an hour (a
// long SOP, a grading lane on a big cohort), and a fixed 3 s poll is ~1,200
// reads an hour per open form. Each unchanged read stretches the wait by
// BACKOFF up to MAX_POLL_MS; any change of state snaps it back to POLL_MS.
const MAX_POLL_MS = 30000;
const BACKOFF = 1.5;

export class EtpAutoRefresh extends Component {
    static template = "assessments_be_v2.EtpAutoRefresh";
    static props = {
        ...standardFieldProps,
        // `options="{'busy_if': 'scoring_requested'}"`. See `isBusy`.
        busyIf: { type: String, optional: true },
    };

    setup() {
        this.state = useState({ stale: false });
        this._timer = null;
        this._delay = POLL_MS;
        this._lastSeen = this.rawValue;
        // Set on unmount and read after every await: a read in flight when the
        // form closes must not schedule another one behind the closed form.
        this._stopped = false;
        onWillStart(() => this._maybeSchedule());
        // A reload hands this SAME component a new record. Every queue button's
        // notification reloads the form, and `onWillStart` fires only once, so
        // a badge already on screen must start polling here when its record
        // turns busy. The backoff resets too, so a new run starts at POLL_MS.
        // Read `next`: `this.props` is still the old record here (R5-01).
        onWillUpdateProps((next) => {
            this._delay = POLL_MS;
            this._lastSeen = next.record.data[next.name];
            this.state.stale = false;
            this._maybeSchedule(next);
        });
        onWillUnmount(() => {
            this._stopped = true;
            this._clear();
        });
    }

    get busySet() {
        return new Set(DEFAULT_BUSY);
    }

    get rawValue() {
        return this.props.record.data[this.props.name];
    }

    get label() {
        const sel = this.props.record.fields[this.props.name].selection || [];
        const hit = sel.find((s) => s[0] === this.rawValue);
        return hit ? hit[1] : (this.rawValue || "");
    }

    /**
     * Busy means in the busy set AND, when the view passes `busy_if`, that
     * field is set.
     *
     * `pending` is the queue state of a generator or a grading run, and also
     * the default `llm_state` of every evaluator: invited, mid-exam, or
     * submitted with auto-grade off. So the Candidates tab gates on
     * `scoring_requested`, which every queue path sets, kill/settle clears, and
     * which stays set through `scoring`. Views without `busy_if` (the
     * generator's SOP and tag badges, the assessment's scoring phase) have no
     * such ambiguous default.
     */
    get isBusy() {
        return this._isBusy(this.props);
    }

    _isBusy(props) {
        const data = props.record.data;
        if (!this.busySet.has(data[props.name])) {
            return false;
        }
        const gate = props.busyIf;
        return !gate || Boolean(data[gate]);
    }

    /**
     * Terminal is not the same as fine. `stalled` renders red, as the list row
     * and the form's alert do: the queue is not moving because the cron that
     * would drain it is not moving. It stays OUT of the busy set, so the badge
     * reloads once to show the alert, then watches it at MAX_POLL_MS.
     */
    get toneClass() {
        if (this.isBusy) {
            return "text-bg-info";
        }
        return this.rawValue === "stalled" ? "text-bg-danger" : "text-bg-secondary";
    }

    _clear() {
        if (this._timer) {
            clearTimeout(this._timer);
            this._timer = null;
        }
    }

    _maybeSchedule(props = this.props) {
        this._clear();
        // `stalled` can clear on its own, so it is watched too, slowly.
        const stalled = props.record.data[props.name] === "stalled";
        if (stalled) {
            this._delay = MAX_POLL_MS;
        }
        if (!this._stopped && (stalled || this._isBusy(props))
                && props.record.resId) {
            this._timer = setTimeout(() => this._poll(), this._delay);
        }
    }

    _backOff() {
        this._delay = Math.min(this._delay * BACKOFF, MAX_POLL_MS);
    }

    async _poll() {
        this._timer = null;
        const rec = this.props.record;
        if (!rec.resId || !(this.isBusy || this.rawValue === "stalled")) {
            return;
        }
        let serverVal = this.rawValue;
        try {
            const rows = await rec.model.orm.read(
                rec.resModel, [rec.resId], [this.props.name]
            );
            if (rows && rows.length) {
                serverVal = rows[0][this.props.name];
            }
        } catch (e) {
            // transient (record locked mid-cron, network blip) — keep polling
            this._backOff();
            this._maybeSchedule();
            return;
        }
        if (this._stopped) {
            return;
        }
        const stalled = this.rawValue === "stalled";
        if (stalled && serverVal === "stalled") {
            this._maybeSchedule();
            return;
        }
        // Leaving `stalled`, for anything, settles like a finished run: the
        // form must drop its alert and the badge pick up the new state.
        if (!this.busySet.has(serverVal) || stalled) {
            // NOT WHILE SOMEBODY IS TYPING. `root.load()` goes through
            // `_setData` without `keepChanges`, which empties `_changes`, so a
            // settle would throw away unsaved edits (on the assessment form,
            // any one candidate row settling). Offer the reload instead; the
            // poll stops either way, because the work has settled.
            if (rec.model.root.dirty) {
                this.state.stale = true;
                return;
            }
            // work settled on the server: pull the whole record into the view
            // so drafts / tags / status all refresh at once.
            await rec.model.root.load();
            rec.model.notify();
            return;
        }
        if (serverVal === this._lastSeen) {
            this._backOff();
        } else {
            this._delay = POLL_MS;
            this._lastSeen = serverVal;
        }
        this._maybeSchedule();
    }

    /** The reload the settle offered but did not take, once the admin says so.
     *  Their edits go first: an unsaved form is saved, then reloaded. */
    async reload() {
        const rec = this.props.record;
        if (rec.model.root.dirty) {
            const saved = await rec.model.root.save();
            if (!saved) {
                return;             // invalid form - leave the hint up
            }
        }
        this.state.stale = false;
        await rec.model.root.load();
        rec.model.notify();
    }
}

export const etpAutoRefresh = {
    component: EtpAutoRefresh,
    displayName: _t("Auto-refreshing status"),
    supportedTypes: ["selection", "char"],
    supportedOptions: [
        {
            label: _t("Only busy when this field is set"),
            name: "busy_if",
            type: "field",
        },
    ],
    extractProps: ({ options }) => ({ busyIf: options.busy_if || undefined }),
};

registry.category("fields").add("be_auto_refresh", etpAutoRefresh);
