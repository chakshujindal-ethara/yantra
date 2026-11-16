import { registry } from "@web/core/registry";
import { Component, onWillStart, onWillUpdateProps, useState } from "@odoo/owl";
import { standardFieldProps } from "@web/views/fields/standard_field_props";
import { useService } from "@web/core/utils/hooks";
import { _t } from "@web/core/l10n/translation";

/**
 * Question-template counts on the generator's "Allowed question types", as the
 * app draws them: one chip per picked template with "x N", -, + and remove, a
 * "Missing form" chip for a count whose template is archived or gone, and a
 * picker for the rest.
 *
 * Bound to `shape_quota_json` - `{"mcq": 2, "template:7": 3}`. Only the
 * `template:<id>` keys are edited here; built-in type counts are shown
 * read-only and carried through untouched. A change that leaves any count also
 * pins the question count to the sum of all counts, as the app does, so the run
 * authors what the chips say.
 *
 * `readonly` (set by the view while a generation runs) hides every control.
 */
const PREFIX = "template:";

export function parseQuotas(raw) {
    try {
        const parsed = JSON.parse(raw || "{}");
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
            return parsed;
        }
    } catch {
        // A malformed value reads as "no counts", as generation treats it.
    }
    return {};
}

export class EtpTemplateQuotas extends Component {
    static template = "assessments_be_v2.EtpTemplateQuotas";
    static props = { ...standardFieldProps };

    setup() {
        this.orm = useService("orm");
        this.state = useState({
            templates: [], types: [], loaded: false, error: "",
        });
        onWillStart(() => this.load());
        // A reloaded form is a new record: re-read the templates, so one
        // archived meanwhile (the Skills & Templates row button reloads the
        // form) leaves the picker.
        onWillUpdateProps((nextProps) => {
            if (nextProps.record !== this.props.record) {
                return this.load();
            }
        });
    }

    async load() {
        this.state.error = "";
        try {
            // Active templates only: an archived one cannot generate, which is
            // exactly what makes its leftover count a "Missing form".
            this.state.templates = await this.orm.searchRead(
                "assessments.be.task.template", [],
                ["name", "item_count", "usable_count"],
                { order: "write_date desc, id desc" }
            );
            // The built-in type counts, drawn read-only (the type picker above
            // owns them): each is summed into the run's total, so it has to be
            // on screen.
            this.state.types = await this.orm.searchRead(
                "assessments.be.question.type", [], ["name", "code"]);
        } catch (error) {
            this.state.error = error.data?.message || error.message || "";
        }
        this.state.loaded = true;
    }

    /** `{name, count}` for every non-template count carried in the field. */
    get typeCounts() {
        const byCode = Object.fromEntries(
            this.state.types.map((t) => [t.code, t.name]));
        return Object.keys(this.quotas)
            .filter((key) => !key.startsWith(PREFIX) && this.countOf(key) > 0)
            .map((key) => ({
                key, count: this.countOf(key), name: byCode[key] || key,
            }));
    }

    get quotas() {
        return parseQuotas(this.props.record.data[this.props.name]);
    }

    countOf(key) {
        return Number(this.quotas[key]) || 0;
    }

    get chosen() {
        return this.state.templates
            .map((tpl) => ({ ...tpl, key: PREFIX + tpl.id }))
            .filter((tpl) => this.countOf(tpl.key) > 0);
    }

    get missing() {
        if (!this.state.loaded || this.state.error) {
            return [];
        }
        const known = new Set(this.state.templates.map((t) => PREFIX + t.id));
        return Object.keys(this.quotas)
            .filter((key) => key.startsWith(PREFIX) && !known.has(key)
                && this.countOf(key) > 0)
            .map((key) => ({ key, id: key.slice(PREFIX.length), count: this.countOf(key) }));
    }

    get remaining() {
        return this.state.templates.filter((tpl) => this.countOf(PREFIX + tpl.id) <= 0);
    }

    health(tpl) {
        if (tpl.item_count && !tpl.usable_count) {
            return _t("GENERATES NOTHING");
        }
        if (tpl.usable_count < tpl.item_count) {
            return _t("only %s/%s usable", tpl.usable_count, tpl.item_count);
        }
        return "";
    }

    async setCount(key, count) {
        const next = { ...this.quotas };
        if (count > 0) {
            next[key] = count;
        } else {
            delete next[key];
        }
        const clean = Object.fromEntries(
            Object.entries(next).filter(([, n]) => Number(n) > 0)
        );
        const total = Object.values(clean).reduce((a, n) => a + Number(n), 0);
        const changes = {
            [this.props.name]: total ? JSON.stringify(clean) : "",
        };
        if (total) {
            changes.sop_question_count = total;
        }
        await this.props.record.update(changes);
    }

    onAdd(ev) {
        const key = ev.target.value;
        ev.target.value = "";
        if (key) {
            this.setCount(key, 1);
        }
    }
}

export const etpTemplateQuotas = {
    component: EtpTemplateQuotas,
    displayName: _t("Question template counts"),
    supportedTypes: ["text", "char"],
};

registry.category("fields").add("be_template_quotas", etpTemplateQuotas);
