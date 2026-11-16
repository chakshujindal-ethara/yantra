/** @odoo-module **/
/*
 * Candidates tab: a searchable, selectable x2many list.
 *
 * An embedded x2many renders without a search bar, so on a large roster there
 * was no way to find one person or act on a subset. This wraps the existing
 * list with a debounced filter box and the bulk actions that make sense for
 * the assessment's current state:
 *
 *   remove              - only before the assessment is launched, i.e. while
 *                         the roster is still being assembled after a CSV
 *                         import; removing a live attempt would destroy data
 *   resend invitation   - while the assessment is running
 *   release results     - once it has ended
 *
 * Filtering is client-side, but NOT over "whatever happens to be loaded".
 * These lists page at 10, and an x2many only holds one page of datapoints, so
 * a naive filter searches the visible page and confidently reports "0
 * match(es)" for somebody sitting on page 3. That is a false negative on a
 * people-search that feeds irreversible bulk actions, so a live query first
 * widens the loaded window to the whole roster and narrows it back when the
 * box is cleared. Both use the PUBLIC `list.load`; nothing here reaches into
 * `_load`, `_currentIds` or `count`, all of which are shared with the draft
 * roster and the Leaderboard on the same record.
 */
import { ConfirmationDialog } from "@web/core/confirmation_dialog/confirmation_dialog";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { X2ManyField, x2ManyField } from "@web/views/fields/x2many/x2many_field";
import { useDebounced } from "@web/core/utils/timing";
import { Component, useState } from "@odoo/owl";

export class CandidateTableField extends X2ManyField {
    static template = "assessments_be_v2.CandidateTable";
    static props = { ...X2ManyField.props };

    setup() {
        super.setup();
        this.orm = useService("orm");
        this.action = useService("action");
        this.notification = useService("notification");
        this.dialog = useService("dialog");
        this.state = useState({ query: "", busy: false, matched: null });
        // Guards a snapshot against the datapoint being replaced underneath it:
        // `record.load()` after a bulk action, and the be_auto_refresh reload
        // when a run settles, both build a BRAND NEW StaticList, leaving
        // `_allRecords` pointing at dead datapoints.
        this._listRef = null;
        // Monotonic, because widening the window awaits a server read and the
        // debounce only coalesces keystrokes - it does not cancel a request
        // already in flight, so two queries can land out of order.
        this._seq = 0;
        // 250ms: long enough to coalesce a burst of keystrokes, short enough
        // that the list still feels live.
        this.onSearchInput = useDebounced((ev) => {
            this.applyFilter((ev.target.value || "").trim());
        }, 250);
    }

    /**
     * Narrow the embedded list by name or email.
     *
     * A static x2many cannot be searched on the server - `StaticList.load`
     * takes limit/offset/orderBy and no domain - so the filter is client-side,
     * done by swapping the list's own `records` array. What it filters OVER is
     * the part that matters: with a page size of 10, `records` is one page, so
     * the window is widened to the whole roster for the duration of a query
     * and narrowed back when the box is cleared.
     *
     * The full set is kept on the side and restored on clear, which also keeps
     * selection and the bulk actions working on whatever is currently visible.
     * Selection deliberately stays scoped to the rendered rows: a bulk action
     * here can release results, which cannot be undone, so it must never be
     * able to reach a row the operator cannot see.
     */
    async applyFilter(query) {
        this.state.query = query;
        const list = this.list;
        if (!list) {
            return;
        }
        if (this._listRef !== list) {
            this._listRef = list;
            this._allRecords = null;
        }
        const seq = ++this._seq;
        // The page size this particular rendering asked for. `archInfo` is
        // per-NODE where `list.limit` is per-FIELD, so this is the one honest
        // record of what the page size should be once a search has widened it.
        const pageLimit = this.archInfo?.limit || 10;
        if (query && list.limit < list.count) {
            // Widen to the whole roster so the filter below is telling the
            // truth. While it is widened `limit === count`, so the inherited
            // pager hides itself rather than paging a filtered table.
            this._allRecords = null;
            await list.load({ limit: list.count, offset: 0 });
        } else if (!query && list.limit !== pageLimit) {
            this._allRecords = null;
            await list.load({ limit: pageLimit, offset: 0 });
        }
        if (seq !== this._seq) {
            return;                     // a later keystroke already answered
        }
        if (!this._allRecords) {
            this._allRecords = list.records.slice();
        }
        const q = query.toLowerCase();
        const kept = !q
            ? this._allRecords.slice()
            : this._allRecords.filter((rec) => {
                  const many2one = rec.data.applicant_id;
                  const name = (Array.isArray(many2one) ? many2one[1] : "") || "";
                  const email = rec.data.candidate_email || "";
                  return (
                      name.toLowerCase().includes(q) ||
                      email.toLowerCase().includes(q)
                  );
              });
        // Mutate in place. The renderer reads the reactive proxy's array, so
        // reassigning list.records swaps an object it is no longer watching
        // and the table keeps showing every row.
        list.records.splice(0, list.records.length, ...kept);
        this.state.matched = q ? kept.length : null;
        this.render(true);
    }

    /**
     * Turn on the row-selector column.
     *
     * An x2many list never passes allowSelectors, and the renderer defaults it
     * to false, so an embedded list has no checkboxes at all. The bulk actions
     * need a selection, so it is enabled here rather than by making the field
     * writable - the rows themselves stay read-only.
     */
    get rendererProps() {
        return { ...super.rendererProps, allowSelectors: true };
    }

    get selectedRecords() {
        return (this.list.records || []).filter((r) => r.selected);
    }

    get assessmentState() {
        return this.props.record.data.state || "draft";
    }

    /** Removing a roster row is only safe before anyone can have sat the exam. */
    get canRemove() {
        return ["draft", "ready"].includes(this.assessmentState);
    }

    get canResend() {
        return ["ready", "in_progress"].includes(this.assessmentState);
    }

    get canRelease() {
        return ["in_progress", "done"].includes(this.assessmentState);
    }

    get selectionCount() {
        return this.selectedRecords.length;
    }

    get selectedIds() {
        return this.selectedRecords.map((r) => r.resId).filter(Boolean);
    }

    async runBulk(method, label, ids = this.selectedIds) {
        if (!ids.length) {
            this.notification.add("Select at least one candidate first.", {
                type: "warning",
            });
            return;
        }
        this.state.busy = true;
        try {
            const result = await this.orm.call(
                "assessments.be.evaluator", method, [ids]
            );
            await this.props.record.load();
            // The roster changed under us; drop the cached copy so a removed
            // candidate cannot come back when the search box is cleared. The
            // load above also replaces the StaticList, which `_listRef` would
            // notice anyway - this just makes it immediate.
            this._allRecords = null;
            this._listRef = null;
            this.state.query = "";
            this.state.matched = null;
            this.render(true);
            const message =
                (result && result.params && result.params.message) ||
                `${label}: ${ids.length} candidate(s).`;
            this.notification.add(message, { type: "success" });
        } finally {
            this.state.busy = false;
        }
    }

    onRemove() {
        return this.runBulk("action_remove_from_assessment", "Removed");
    }

    onResend() {
        return this.runBulk("action_requeue_invitation", "Invitation resent");
    }

    onRelease() {
        // Q13: every one-click Release asks first. The ids are taken now:
        // an auto-refresh while the dialog is open rebuilds the list and
        // its selection, and Release must act on the rows the count named.
        const ids = this.selectedIds;
        this.dialog.add(ConfirmationDialog, {
            title: "Release results",
            body:
                `Release results for the ${ids.length} selected ` +
                "candidate(s)? Each of them sees their marks at once. This " +
                "cannot be undone - once released, there is no way to take " +
                "them back.",
            confirmLabel: "Release",
            confirm: () =>
                this.runBulk("action_release_results", "Results released", ids),
            cancel: () => {},
        });
    }
}

export const candidateTableField = {
    ...x2ManyField,
    component: CandidateTableField,
};

registry.category("fields").add("be_candidate_table", candidateTableField);
