import { registry } from "@web/core/registry";
import { useState, useRef, onMounted, onPatched, onWillUnmount } from "@odoo/owl";
import { _t } from "@web/core/l10n/translation";
import { TextField, textField } from "@web/views/fields/text/text_field";

/**
 * A drop-in replacement for widget="text" that CLAMPS long values to a few
 * lines behind a small GitHub-style expand/collapse chevron, instead of
 * dumping the whole blob at full height.
 *
 * The affordance is a minimal, icon-only chevron button floating at the
 * BOTTOM-RIGHT corner of the field: it points DOWN when collapsed (click to
 * expand) and UP when expanded (click to collapse), and shows an "Expand" /
 * "Collapse" tooltip on hover (Odoo's data-tooltip). No text label - subtle
 * and out of the way.
 *
 * Motivation: JSON answer keys (subjective_rubric_json, detections_json,
 * dom_manifest_json, behavioural_key_json, options_json, rubric_json, ...) can
 * run to hundreds of lines. Rendered raw they blow the form (and editable-list
 * rows) into a wall of text you have to scroll past. This widget shows the
 * first few lines and reveals the rest only when the admin clicks the chevron.
 *
 * It EXTENDS the stock TextField so edit-mode behaviour (autoresize textarea,
 * translation button, dynamic placeholder, parsing/trim) is unchanged - the
 * clamp is a wrapper around the same inner markup. A focus into the textarea
 * auto-expands so editing a clipped value is never awkward.
 *
 * Registered for both form (be_collapsible_text) and list
 * (list.be_collapsible_text) so it works in editable-list cells too.
 *
 * Usage:  <field name="detections_json" widget="be_collapsible_text"/>
 */

// Slack so a value that fits in the clamp by a hair (sub-pixel rounding,
// scrollbar) doesn't spuriously show a chevron that reveals nothing.
const COLLAPSE_SLACK_PX = 4;

export class EtpCollapsibleText extends TextField {
    static template = "assessments_be_v2.EtpCollapsibleText";

    setup() {
        super.setup();
        this.collapse = useState({ expanded: false, overflowing: false });
        this.clampRef = useRef("clamp");
        // Recompute overflow on ANY layout change that affects the clamp's
        // rendered size - not just OWL re-renders. onMounted/onPatched alone
        // miss pure CSS reflows (the grid-column width fix that widens the
        // field 150px -> full width, a tab switching from hidden to visible so
        // height goes 0 -> real, a window resize, an async monospace font
        // load). Those left `overflowing` stale, so a short value that now
        // fits kept showing a chevron that revealed nothing. A ResizeObserver
        // on the clamp catches every one of those.
        this._resizeObserver = new ResizeObserver(() => this._measure());
        onMounted(() => {
            if (this.clampRef.el) {
                this._resizeObserver.observe(this.clampRef.el);
            }
            this._measure();
        });
        onPatched(() => this._measure());
        onWillUnmount(() => this._resizeObserver.disconnect());
    }

    /**
     * Detect whether the clamped content actually overflows its capped height,
     * and gate the chevron on that. Guarded so it only writes state on a real
     * change - otherwise onPatched/observer -> setState -> patch could loop.
     * When the field is hidden (inactive tab) both heights are 0, which reads
     * as "not overflowing" until the ResizeObserver fires once it is shown.
     */
    _measure() {
        const el = this.clampRef.el;
        if (!el || this.collapse.expanded) {
            // While expanded the clamp is un-capped (scrollHeight ~= clientHeight);
            // don't recompute or we'd drop the "Collapse" affordance. The
            // expanded flag alone keeps the toggle visible.
            return;
        }
        // Compare the true content height against the collapsed CAP (max-height),
        // NOT clientHeight. In an editable form the inner content is an
        // autoresizing <textarea> plus a small input-buttons chrome div, so
        // clientHeight tracks the textarea's own height (and that chrome) - which
        // made scrollHeight-clientHeight report a few phantom px of "overflow" on
        // short values and show a chevron that revealed nothing. The cap is the
        // real clip line: content overflows only if it is taller than the cap.
        const cap = parseFloat(getComputedStyle(el).maxHeight);
        const overflowing = Number.isFinite(cap)
            ? el.scrollHeight > cap + COLLAPSE_SLACK_PX
            : el.scrollHeight - el.clientHeight > COLLAPSE_SLACK_PX;
        if (overflowing !== this.collapse.overflowing) {
            this.collapse.overflowing = overflowing;
        }
    }

    get showToggle() {
        return this.collapse.overflowing || this.collapse.expanded;
    }

    get toggleTitle() {
        return this.collapse.expanded ? _t("Collapse") : _t("Expand");
    }

    toggle() {
        this.collapse.expanded = !this.collapse.expanded;
    }

    onFocusIn() {
        // Editing a clipped textarea is painful - reveal it fully on focus.
        if (!this.props.readonly && !this.collapse.expanded) {
            this.collapse.expanded = true;
        }
    }
}

export const etpCollapsibleText = {
    ...textField,
    component: EtpCollapsibleText,
    displayName: _t("Collapsible text"),
};

registry.category("fields").add("be_collapsible_text", etpCollapsibleText);
registry.category("fields").add("list.be_collapsible_text", etpCollapsibleText);
