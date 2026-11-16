/** @odoo-module **/
/*
 * Form Studio's item editor, in Odoo. Two uses:
 *
 *   * A Form Studio form - READ-ONLY (the view sets `readonly`): the Flutter
 *     designer owns authoring and would overwrite an Odoo edit. The editor
 *     draws the form and runs the publish check.
 *   * A task template - editable, in template mode (`skip_publish_check`): a
 *     template is never published and its answer keys are optional.
 *
 * THIS WIDGET OWNS NO RULES, AND THAT IS THE WHOLE DESIGN. Three things decide
 * what a form may contain, and all three live on the server:
 *
 *   * WHICH TYPES EXIST - `etp.studio.form.form_item_kinds()`, straight out of
 *     `constants.FORM_ITEM_KINDS`, the same catalogue `_item_spec` branches on.
 *     A hardcoded list here is how an editor offers a kind publish refuses, or
 *     hides one it accepts.
 *   * WHETHER THE FORM IS PUBLISHABLE - `validate_structure()`, which runs the
 *     exact walk `publish_to_assessment` runs and creates nothing. Every message
 *     shown here is the message Publish would raise, item by item, as the
 *     operator works instead of at the end of the job.
 *   * WHERE MEDIA IS STORED - `/api/v1/forms/media` and `.../media/import`, the
 *     same two routes the Flutter designer posts to. Called by `fetch` on the
 *     back-office session rather than reimplemented as ORM methods, so the
 *     bucket prefix, the key shape, the SSRF allow-list, the per-hop redirect
 *     check and the content-type gate stay in exactly one place - the place
 *     `studio_form._fetch_s3_object` reads back at publish time.
 *
 * SAVING IS EXPLICIT, AND IT SAYS SO. Leaving a field applies the change to the
 * record (which arms Odoo's own unsaved-changes guard); the Save button in this
 * widget's toolbar is what writes it, and it toasts and stamps the time. An
 * authoring surface's worst outcome is a lost edit, so nothing here saves
 * silently and nothing here refuses to save: a form mid-authoring is allowed to
 * be unpublishable, and the toolbar says how many problems are still open rather
 * than holding the work hostage.
 */
import { registry } from "@web/core/registry";
import { standardFieldProps } from "@web/views/fields/standard_field_props";
import { useService } from "@web/core/utils/hooks";
import { useDebounced } from "@web/core/utils/timing";
import { ConfirmationDialog } from "@web/core/confirmation_dialog/confirmation_dialog";
import { uuid } from "@web/core/utils/strings";
import { _t } from "@web/core/l10n/translation";
import {
    Component, onMounted, onPatched, onWillStart, useRef, useState,
} from "@odoo/owl";

// The designer's media routes, both of them. Named once so the two call sites
// below cannot drift from each other, and so a version bump of the API prefix
// is one edit here - `_fetch_media_b64` already matches `/api/v\d+/` when it
// reads these keys back at publish time.
const MEDIA_UPLOAD_URL = "/api/v1/forms/media";
const MEDIA_IMPORT_URL = "/api/v1/forms/media/import";

// What an unrecognised kind is drawn as. A form authored in a NEWER designer
// than this Odoo, or one carrying a kind that was retired, must still open: the
// operator can read it, fix its text and - if they want - convert it, and the
// item's own fields are preserved untouched either way. Falling over, or
// silently dropping the item, are both worse than saying so.
const UNKNOWN_KIND = {
    kind: "",
    label: _t("Unrecognised type"),
    family: "",
    role: "refused",
    needs: [],
    flags: [],
    hint: _t(
        "This module does not know this question type, so it cannot show its " +
        "fields. Publishing skips the item with a warning. Its stored data is " +
        "left exactly as it is unless you change the type."
    ),
};

export class FormItemEditor extends Component {
    static template = "assessments_be_v2.FormItemEditor";
    static props = {
        ...standardFieldProps,
        // A task template is authored in this same editor but is never
        // published, and a template's answer keys are optional - so it skips
        // the publish check (`validate_structure`), which demands them. Off by
        // default: Form Studio forms are checked exactly as before.
        skipPublishCheck: { type: Boolean, optional: true },
    };

    setup() {
        this.orm = useService("orm");
        this.dialog = useService("dialog");
        this.notification = useService("notification");

        this.state = useState({
            // The server's catalogue. Empty until onWillStart answers, which is
            // why the template has a loading state rather than rendering an
            // empty type picker for a moment.
            kinds: [],
            loading: true,
            catalogueError: "",
            // The last answer from `validate_structure`, plus its own errors:
            // a failed check must not read as "no problems".
            check: null,
            checking: false,
            checkError: "",
            // Per item-key UI state. Collapse is view-only and never persisted,
            // exactly as the Flutter item card treats it.
            collapsed: {},
            mediaBusy: {},
            mediaError: {},
            saving: false,
            savedAt: "",
        });

        // MUTATIONS ARE SERIALISED. Every edit deep-clones the document,
        // mutates the clone and hands it to `record.update`, which is async.
        // Two edits in flight (blur a field, immediately click a button) could
        // otherwise both clone the same pre-edit document and the second would
        // silently undo the first. `onSave` awaits this chain for the same
        // reason: clicking Save blurs the field being typed in, so the commit
        // that blur triggers has to land before the write.
        this._queue = Promise.resolve();
        // Monotonic, because validation is debounced but not cancellable: two
        // checks can land out of order and the older one must not win.
        this._checkSeq = 0;
        // 400ms - long enough to coalesce a burst of edits, short enough that
        // the problem list feels like it is answering the current document.
        this.validateSoon = useDebounced(() => this.validate(), 400);

        onWillStart(async () => {
            await Promise.all([this.loadCatalogue(), this.validate()]);
            this.state.loading = false;
        });

        // See `syncInputs`: every text box's value is pushed into the DOM here
        // rather than bound in the template.
        this.rootRef = useRef("editorRoot");
        onMounted(() => this.syncInputs());
        onPatched(() => this.syncInputs());
    }

    /**
     * Put the document's text into the boxes - EXCEPT the one being typed in.
     *
     * THIS IS WHY THE TEMPLATE BINDS `data-value` AND NOT `value`. OWL treats
     * `value` on an input as a PROPERTY and re-asserts it on every patch,
     * deliberately bypassing the equality check. This widget re-renders on
     * things the operator did not do - a debounced validation answering 400ms
     * later, an upload finishing - so a bound `value` would overwrite whatever
     * had been typed since, and reset the caret to the end even when the text
     * was unchanged. On an authoring surface that is a lost edit, which is the
     * one outcome worth designing against.
     *
     * The focused element is therefore never touched, and the others are only
     * written when they actually differ. `useInputField` solves the same problem
     * the same way for stock fields; this is that discipline applied to a form
     * whose boxes are built by a loop rather than declared one by one.
     */
    syncInputs() {
        const root = this.rootRef.el;
        if (!root) {
            return;
        }
        for (const el of root.querySelectorAll("[data-value]")) {
            if (el === document.activeElement) {
                continue;
            }
            const wanted = el.dataset.value ?? "";
            if (el.value !== wanted) {
                el.value = wanted;
            }
        }
    }

    // ── server calls ────────────────────────────────────────────────────

    async loadCatalogue() {
        this.state.catalogueError = "";
        try {
            this.state.kinds = await this.orm.call(
                "etp.studio.form", "form_item_kinds", []
            );
        } catch (error) {
            // Caught, not left to the global handler: a dialog over the whole
            // screen for a list of type labels would hide a form the operator
            // can still fix the text of. The banner offers a retry instead.
            this.state.catalogueError =
                error.data?.message || error.message || _t("Unknown error");
        }
    }

    /**
     * Ask the server what publish would refuse this document for.
     *
     * The document sent is the one in the record RIGHT NOW, saved or not, so
     * the answer describes what the operator is looking at.
     */
    async validate() {
        if (this.props.skipPublishCheck) {
            return;
        }
        const seq = ++this._checkSeq;
        this.state.checking = true;
        this.state.checkError = "";
        try {
            const result = await this.orm.call(
                "etp.studio.form", "validate_structure", [this.sections]
            );
            if (seq === this._checkSeq) {
                this.state.check = result;
            }
        } catch (error) {
            if (seq === this._checkSeq) {
                // NEVER fall back to "looks fine". A check that did not run is
                // its own state, said out loud, because the alternative is an
                // operator pressing Publish on a form nothing validated.
                this.state.check = null;
                this.state.checkError =
                    error.data?.message || error.message || _t("Unknown error");
            }
        } finally {
            if (seq === this._checkSeq) {
                this.state.checking = false;
            }
        }
    }

    // ── the document, and how it is changed ─────────────────────────────

    get sections() {
        const value = this.props.record.data[this.props.name];
        return Array.isArray(value) ? value : [];
    }

    get editable() {
        return !this.props.readonly;
    }

    get dirty() {
        return Boolean(this.props.record.dirty);
    }

    /**
     * Apply [mutate] to a DEEP CLONE of the document and write it back.
     *
     * The clone is what makes an unknown field safe: every key this editor does
     * not understand - a designer's own `media_kind`, an annotation's drawn
     * `regions`, whatever the next client version adds - is carried through
     * untouched, because nothing is rebuilt from the fields the widget knows.
     * Mutating the record's own array in place would also not register as a
     * change, so the save button would have nothing to write.
     */
    commit(mutate) {
        this._queue = this._queue
            .catch(() => {})
            .then(async () => {
                const next = JSON.parse(JSON.stringify(this.sections));
                mutate(next);
                await this.props.record.update({ [this.props.name]: next });
            });
        this._queue.then(() => this.validateSoon());
        return this._queue;
    }

    /** One item, addressed the way every handler here addresses one. */
    editItem(sectionIndex, itemIndex, mutate) {
        return this.commit((sections) => {
            const item = sections[sectionIndex]?.items?.[itemIndex];
            if (item) {
                mutate(item);
            }
        });
    }

    async onSave() {
        await this._queue.catch(() => {});
        this.state.saving = true;
        try {
            const saved = await this.props.record.save();
            if (saved) {
                this.state.savedAt = new Date().toLocaleTimeString();
                this.notification.add(_t("Form structure saved."), {
                    type: "success",
                });
            } else {
                // `save()` answers false when the record itself is invalid -
                // a required field elsewhere on the form, typically. Silence
                // here would read as a successful save.
                this.notification.add(
                    _t("Nothing was saved - check the rest of the form for " +
                       "fields that still need a value."),
                    { type: "warning" }
                );
            }
        } finally {
            this.state.saving = false;
        }
    }

    confirm(title, body, confirmLabel, onConfirm) {
        this.dialog.add(ConfirmationDialog, {
            title,
            body,
            confirmLabel,
            confirmClass: "btn-danger",
            confirm: onConfirm,
            cancel: () => {},
        });
    }

    // ── the catalogue ───────────────────────────────────────────────────

    kindOf(item) {
        const code = (item && item.kind) || "";
        return (
            this.state.kinds.find((k) => k.kind === code) || {
                ...UNKNOWN_KIND,
                kind: code,
                label: code
                    ? _t('Unrecognised type "%s"', code)
                    : UNKNOWN_KIND.label,
            }
        );
    }

    needs(item, token) {
        return (this.kindOf(item).needs || []).includes(token);
    }

    /** Whether the catalogue actually has this item's kind in it. */
    isKnownKind(item) {
        const code = (item && item.kind) || "";
        return this.state.kinds.some((kind) => kind.kind === code);
    }

    /**
     * Whether a section is a shape this editor can draw.
     *
     * The document is a jsonb column the API writes too, and `_walk_document`
     * skips a non-dict section rather than failing, so this is reachable. Said
     * out loud and left untouched: silently hiding it would lose it on the next
     * save, which is exactly the data loss this whole surface must not cause.
     */
    isReadableSection(section) {
        return Boolean(section) && typeof section === "object" &&
            !Array.isArray(section);
    }

    /**
     * A problem message with the "which item is this about" prefix removed.
     *
     * `_where` builds every server message as `"<title>" (section "<name>"): …`
     * because the API returns a flat list with no other way to say which item it
     * means. Inside the item's own card that prefix is noise repeated on every
     * line, so it is stripped - by REBUILDING the exact prefix from the same two
     * strings and matching it, never by cutting at the first colon, which would
     * eat into a title that contains one. Anything that does not match is shown
     * whole: a message with no owner is still a message.
     */
    whereOf(item, sectionTitle) {
        const title = String((item && item.title) || "").trim() ||
            "Untitled question";
        const section = String(sectionTitle || "").trim();
        return section
            ? `"${title}" (section "${section}")`
            : `"${title}"`;
    }

    shortProblem(text, item, sectionTitle) {
        const message = String(text || "");
        const prefix = `${this.whereOf(item, sectionTitle)}: `;
        return message.startsWith(prefix)
            ? message.slice(prefix.length)
            : message;
    }

    /**
     * Whether this form has already been published.
     *
     * Publishing COPIES the form into bank questions and a draft assessment, so
     * an edit here does not reach the paper that was already created - a real
     * misreading, worth a banner rather than a surprise. Off when read-only:
     * there is no edit to warn about. Read defensively because a view could
     * bind this widget without the field beside it.
     */
    get alreadySent() {
        return Boolean(this.props.record.data.published) && !this.props.readonly;
    }

    /** Options are required for some kinds and merely allowed for others. */
    wantsOptions(item) {
        return (
            this.needs(item, "options") || this.needs(item, "options_optional")
        );
    }

    wantsGolden(item) {
        return (
            this.needs(item, "golden") ||
            this.needs(item, "golden_optional") ||
            this.needs(item, "golden_point")
        );
    }

    /** True when several options may be marked correct on this kind. */
    multiKey(item) {
        return this.needs(item, "multi_key") || Boolean(item.multi_select);
    }

    /**
     * The badge a kind's role earns, in the operator's words.
     *
     * `role` is the server's answer to "what does publish do with this", and
     * the four values are genuinely different outcomes - see FORM_ITEM_KINDS.
     */
    roleLabel(item) {
        const kind = this.kindOf(item);
        if (kind.role === "informational") {
            return _t("Not a question");
        }
        if (kind.role === "refused") {
            return _t("Cannot be published");
        }
        if (kind.role === "media") {
            return this.optionsOf(item).length
                ? _t("Question")
                : _t("Not a question yet");
        }
        return _t("Question");
    }

    // ── item and section identity ───────────────────────────────────────

    /**
     * The key UI state is filed under.
     *
     * The item's OWN id when it has one, because an index key follows the slot
     * rather than the item: reordering two items would swap their collapsed
     * state, and deleting one would hand its state to whatever moved up.
     */
    itemKey(item, sectionIndex, itemIndex) {
        return (item && item.id) || `${sectionIndex}:${itemIndex}`;
    }

    isCollapsed(item, sectionIndex, itemIndex) {
        return Boolean(this.state.collapsed[
            this.itemKey(item, sectionIndex, itemIndex)]);
    }

    toggleCollapsed(item, sectionIndex, itemIndex) {
        const key = this.itemKey(item, sectionIndex, itemIndex);
        this.state.collapsed[key] = !this.state.collapsed[key];
    }

    setAllCollapsed(collapsed) {
        const next = {};
        if (collapsed) {
            this.sections.forEach((section, si) =>
                (section.items || []).forEach((item, ii) => {
                    next[this.itemKey(item, si, ii)] = true;
                })
            );
        }
        this.state.collapsed = next;
    }

    // ── what validation said, per item and per form ─────────────────────

    itemIssues(sectionIndex, itemIndex) {
        const rows = this.state.check?.items || [];
        return (
            rows.find(
                (row) => row.section === sectionIndex && row.item === itemIndex
            ) || { problems: [], warnings: [] }
        );
    }

    /**
     * The problems that belong to the FORM rather than to any one item.
     *
     * The per-item panels already carry their own, so repeating them at the top
     * would double every message and bury the form-level ones - "no question can
     * be delivered", the size ceiling - which are the two an operator cannot act
     * on from inside an item card.
     */
    get formProblems() {
        const check = this.state.check;
        if (!check) {
            return [];
        }
        const owned = new Set();
        for (const row of check.items || []) {
            for (const problem of row.problems || []) {
                owned.add(problem);
            }
        }
        return (check.problems || []).filter((p) => !owned.has(p));
    }

    get formWarnings() {
        const check = this.state.check;
        if (!check) {
            return [];
        }
        const owned = new Set();
        for (const row of check.items || []) {
            for (const warning of row.warnings || []) {
                owned.add(warning);
            }
        }
        return (check.warnings || []).filter((w) => !owned.has(w));
    }

    get problemCount() {
        return (this.state.check?.problems || []).length;
    }

    get questionCount() {
        return this.state.check?.questions || 0;
    }

    // ── sections ────────────────────────────────────────────────────────

    newSection() {
        return { id: uuid(), title: "", items: [] };
    }

    onAddSection() {
        this.commit((sections) => sections.push(this.newSection()));
    }

    onSectionTitle(sectionIndex, ev) {
        const title = ev.target.value;
        this.commit((sections) => {
            if (sections[sectionIndex]) {
                sections[sectionIndex].title = title;
            }
        });
    }

    onMoveSection(sectionIndex, delta) {
        this.commit((sections) => {
            const to = sectionIndex + delta;
            if (to < 0 || to >= sections.length) {
                return;
            }
            const [moved] = sections.splice(sectionIndex, 1);
            sections.splice(to, 0, moved);
        });
    }

    onDeleteSection(sectionIndex) {
        const section = this.sections[sectionIndex];
        const count = (section?.items || []).length;
        const remove = () =>
            this.commit((sections) => sections.splice(sectionIndex, 1));
        if (!count) {
            // An empty section holds no authored work, so a confirm on it is
            // just a click in the way.
            return remove();
        }
        this.confirm(
            _t("Delete this section?"),
            _t("%s item(s) in it will be deleted too. This cannot be undone " +
               "once you save.", count),
            _t("Delete section"),
            remove
        );
    }

    // ── items ───────────────────────────────────────────────────────────

    /**
     * A blank item of [kindCode], seeded with the fields that kind needs.
     *
     * SEEDED, NOT LEFT EMPTY, because the shape is what publish and the Flutter
     * designer both read: an options-carrying kind with no `options` key at all
     * reads as "no options" everywhere, and an operator adding a choice question
     * would have to find the Add option button before the item was anything but
     * broken. Two options, because one option is not a choice and publish says
     * so.
     */
    newItem(kindCode) {
        const item = { id: uuid(), kind: kindCode, title: "", help: "" };
        const kind = this.kindOf(item);
        const needs = kind.needs || [];
        if (needs.includes("options")) {
            item.options = [this.newOption(), this.newOption()];
        }
        if (needs.includes("grid")) {
            // PLAIN STRINGS. `_item_spec` coerces rows and columns with
            // `str(...)`, so a dict here would stringify to "{'label': 'x'}"
            // and become a column labelled with its own source code.
            item.rows = ["", ""];
            item.columns = ["", ""];
            item.grid_key = {};
        }
        if (needs.includes("scale")) {
            Object.assign(item, {
                scale_min: 1,
                scale_max: 5,
                scale_min_label: "",
                scale_max_label: "",
            });
        }
        if (needs.includes("rating")) {
            item.rating_max = 5;
        }
        if (this.wantsGolden(item)) {
            item.golden_answer = "";
        }
        if (needs.includes("media") || needs.includes("media_b")) {
            item.media_url = "";
        }
        if (needs.includes("media_b")) {
            item.media_url_b = "";
        }
        if (needs.includes("regions")) {
            item.annotation_count = 1;
            item.golden_labels = {};
        }
        return item;
    }

    onAddItem(sectionIndex, ev) {
        const kindCode = ev.target.value;
        if (!kindCode) {
            return;
        }
        // Reset the picker: it is an action, not a value, so leaving the last
        // choice selected would suggest the section has a "current type".
        ev.target.value = "";
        this.commit((sections) => {
            const section = sections[sectionIndex];
            if (section) {
                section.items = section.items || [];
                section.items.push(this.newItem(kindCode));
            }
        });
    }

    onMoveItem(sectionIndex, itemIndex, delta) {
        this.commit((sections) => {
            const items = sections[sectionIndex]?.items;
            const to = itemIndex + delta;
            if (!items || to < 0 || to >= items.length) {
                return;
            }
            const [moved] = items.splice(itemIndex, 1);
            items.splice(to, 0, moved);
        });
    }

    onDuplicateItem(sectionIndex, itemIndex) {
        this.commit((sections) => {
            const items = sections[sectionIndex]?.items;
            const item = items?.[itemIndex];
            if (!item) {
                return;
            }
            const copy = JSON.parse(JSON.stringify(item));
            // A FRESH ID, on the item and on every option. `source_ref` is
            // `form:<uid>#<item id>`, so two items sharing an id publish as two
            // questions claiming the same provenance - and an edit to one would
            // look like an edit to both.
            copy.id = uuid();
            for (const option of copy.options || []) {
                if (option && typeof option === "object") {
                    option.id = uuid();
                }
            }
            items.splice(itemIndex + 1, 0, copy);
        });
    }

    onDeleteItem(sectionIndex, itemIndex) {
        const item = this.sections[sectionIndex]?.items?.[itemIndex];
        const title = (item?.title || "").trim();
        this.confirm(
            _t("Delete this item?"),
            title
                ? _t('"%s" will be removed from the form.', title)
                : _t("This untitled item will be removed from the form."),
            _t("Delete item"),
            () =>
                this.commit((sections) =>
                    sections[sectionIndex]?.items?.splice(itemIndex, 1)
                )
        );
    }

    onItemField(sectionIndex, itemIndex, field, ev) {
        const value = ev.target.value;
        this.editItem(sectionIndex, itemIndex, (item) => {
            item[field] = value;
        });
    }

    onItemNumber(sectionIndex, itemIndex, field, ev) {
        // Parsed here rather than left as a string, because `_item_spec` reads
        // these with `int(...)` and a blank box would become 0: a scale of 0..0
        // is not a scale, and the message an operator would get names the
        // range instead of the empty box that caused it.
        const raw = ev.target.value;
        const parsed = parseInt(raw, 10);
        this.editItem(sectionIndex, itemIndex, (item) => {
            item[field] = Number.isNaN(parsed) ? "" : parsed;
        });
    }

    onItemFlag(sectionIndex, itemIndex, field, ev) {
        const checked = ev.target.checked;
        this.editItem(sectionIndex, itemIndex, (item) => {
            item[field] = checked;
        });
    }

    /**
     * Change an item's type, keeping everything it already carries.
     *
     * NOTHING IS DELETED on a type change - not the options, not the golden
     * answer, not the media. An operator switching multiple choice to
     * checkboxes, or fixing a kind they picked by mistake, must not lose the
     * work; publish reads only the fields the new kind needs and the editor
     * only draws those, so a leftover field is inert rather than harmful. The
     * fields the NEW kind needs and the item lacks are seeded, so the item is
     * immediately editable as that kind.
     */
    onItemKind(sectionIndex, itemIndex, ev) {
        const kindCode = ev.target.value;
        this.editItem(sectionIndex, itemIndex, (item) => {
            item.kind = kindCode;
            const seeded = this.newItem(kindCode);
            for (const [key, value] of Object.entries(seeded)) {
                if (key === "id" || key === "kind") {
                    continue;
                }
                if (item[key] === undefined || item[key] === null) {
                    item[key] = value;
                }
            }
        });
    }

    // ── options ─────────────────────────────────────────────────────────

    newOption() {
        return { id: uuid(), label: "", correct: false };
    }

    optionsOf(item) {
        const options = (item && item.options) || [];
        return Array.isArray(options) ? options : [];
    }

    onAddOption(sectionIndex, itemIndex) {
        this.editItem(sectionIndex, itemIndex, (item) => {
            item.options = this.optionsOf(item);
            item.options.push(this.newOption());
        });
    }

    onOptionLabel(sectionIndex, itemIndex, optionIndex, ev) {
        const label = ev.target.value;
        this.editItem(sectionIndex, itemIndex, (item) => {
            const option = item.options?.[optionIndex];
            if (option) {
                option.label = label;
            }
        });
    }

    /**
     * Mark an option correct - the answer key.
     *
     * On a single-answer kind, marking one UNMARKS the rest. Publish refuses a
     * single-select key naming two correct options, and for a reason worth
     * repeating: scoring matches the chosen set exactly, so a radio group can
     * never equal a two-correct key and every candidate silently loses that
     * mark. Enforcing it in the control is kinder than reporting it afterwards.
     */
    onOptionCorrect(sectionIndex, itemIndex, optionIndex, ev) {
        const checked = ev.target.checked;
        this.editItem(sectionIndex, itemIndex, (item) => {
            const options = this.optionsOf(item);
            const single = !this.multiKey(item);
            options.forEach((option, index) => {
                if (index === optionIndex) {
                    option.correct = checked;
                } else if (single && checked) {
                    option.correct = false;
                }
            });
        });
    }

    onMoveOption(sectionIndex, itemIndex, optionIndex, delta) {
        this.editItem(sectionIndex, itemIndex, (item) => {
            const options = item.options || [];
            const to = optionIndex + delta;
            if (to < 0 || to >= options.length) {
                return;
            }
            const [moved] = options.splice(optionIndex, 1);
            options.splice(to, 0, moved);
        });
    }

    onDeleteOption(sectionIndex, itemIndex, optionIndex) {
        this.editItem(sectionIndex, itemIndex, (item) =>
            (item.options || []).splice(optionIndex, 1)
        );
    }

    // ── grids ───────────────────────────────────────────────────────────

    rowsOf(item) {
        const rows = (item && item.rows) || [];
        return Array.isArray(rows) ? rows.map((row) => String(row ?? "")) : [];
    }

    columnsOf(item) {
        const columns = (item && item.columns) || [];
        return Array.isArray(columns)
            ? columns.map((column) => String(column ?? ""))
            : [];
    }

    /** The column labels keyed correct for one row, as a Set. */
    gridKeyOf(item, rowIndex) {
        const raw = (item && item.grid_key) || {};
        const value = raw[String(rowIndex)] ?? raw[rowIndex];
        const list = Array.isArray(value) ? value : [value];
        return new Set(
            list
                .filter((entry) => entry !== undefined && entry !== null)
                .map((entry) => String(entry).trim())
                .filter(Boolean)
        );
    }

    isGridKeyed(item, rowIndex, column) {
        return this.gridKeyOf(item, rowIndex).has(column);
    }

    onGridRow(sectionIndex, itemIndex, rowIndex, ev) {
        const label = ev.target.value;
        this.editItem(sectionIndex, itemIndex, (item) => {
            item.rows = this.rowsOf(item);
            item.rows[rowIndex] = label;
        });
    }

    onGridColumn(sectionIndex, itemIndex, columnIndex, ev) {
        const label = ev.target.value;
        this.editItem(sectionIndex, itemIndex, (item) => {
            const before = this.columnsOf(item)[columnIndex];
            item.columns = this.columnsOf(item);
            item.columns[columnIndex] = label;
            // FOLLOW THE RENAME INTO THE KEY. A row's key names its column by
            // LABEL, and `_grid_row_key` filters the key against the current
            // columns - so renaming a keyed column silently unkeys every row
            // that named it, and publish then refuses the whole form over rows
            // the operator can see are keyed.
            const key = item.grid_key || {};
            for (const [rowKey, value] of Object.entries(key)) {
                const list = Array.isArray(value) ? value : [value];
                const next = list.map((entry) =>
                    String(entry ?? "").trim() === String(before ?? "").trim()
                        ? label
                        : entry
                );
                key[rowKey] = Array.isArray(value) ? next : next[0];
            }
            item.grid_key = key;
        });
    }

    onAddGridRow(sectionIndex, itemIndex) {
        this.editItem(sectionIndex, itemIndex, (item) => {
            item.rows = this.rowsOf(item);
            item.rows.push("");
        });
    }

    onAddGridColumn(sectionIndex, itemIndex) {
        this.editItem(sectionIndex, itemIndex, (item) => {
            item.columns = this.columnsOf(item);
            item.columns.push("");
        });
    }

    onDeleteGridRow(sectionIndex, itemIndex, rowIndex) {
        this.editItem(sectionIndex, itemIndex, (item) => {
            const rows = this.rowsOf(item);
            rows.splice(rowIndex, 1);
            item.rows = rows;
            // The key is indexed BY ROW POSITION, so removing a row without
            // shifting the keys above it moves every one of them onto the wrong
            // row - the answer key would still be complete and would grade the
            // wrong answers correct.
            const old = item.grid_key || {};
            const next = {};
            for (const [rowKey, value] of Object.entries(old)) {
                const index = parseInt(rowKey, 10);
                if (Number.isNaN(index) || index === rowIndex) {
                    continue;
                }
                next[String(index > rowIndex ? index - 1 : index)] = value;
            }
            item.grid_key = next;
        });
    }

    onDeleteGridColumn(sectionIndex, itemIndex, columnIndex) {
        this.editItem(sectionIndex, itemIndex, (item) => {
            const columns = this.columnsOf(item);
            const [removed] = columns.splice(columnIndex, 1);
            item.columns = columns;
            // Drop the deleted label out of every row's key, for the same
            // reason the rename above follows it: a key naming a column that no
            // longer exists reads as an UNKEYED row and publish refuses it.
            const key = item.grid_key || {};
            for (const [rowKey, value] of Object.entries(key)) {
                const list = Array.isArray(value) ? value : [value];
                const kept = list.filter(
                    (entry) =>
                        String(entry ?? "").trim() !==
                        String(removed ?? "").trim()
                );
                key[rowKey] = Array.isArray(value) ? kept : kept[0] || "";
            }
            item.grid_key = key;
        });
    }

    onGridKey(sectionIndex, itemIndex, rowIndex, column, ev) {
        const checked = ev.target.checked;
        this.editItem(sectionIndex, itemIndex, (item) => {
            const multi = this.multiKey(item);
            const current = this.gridKeyOf(item, rowIndex);
            if (checked) {
                if (!multi) {
                    current.clear();
                }
                current.add(column);
            } else {
                current.delete(column);
            }
            const key = item.grid_key || {};
            // A CHECKBOX GRID ROW KEEPS A LIST and a radio grid a bare string,
            // which is what the designer writes for each and what
            // `_grid_row_key` reads back: a checkbox row is an MSQ, so a row
            // where two columns are right cannot be expressed as one value.
            key[String(rowIndex)] = multi
                ? [...current]
                : [...current][0] || "";
            item.grid_key = key;
        });
    }

    // ── scales, ratings and their golden point ──────────────────────────

    /**
     * The pickable points of a scale or rating item, as strings.
     *
     * The golden answer for these kinds is one of these points and publish
     * checks it is (`golden.isdigit()` and within range), so the control is a
     * picker rather than a free-text box - a typo cannot become an unpublishable
     * form.
     */
    scalePoints(item) {
        let min = 1;
        let max = 5;
        if (this.needs(item, "rating")) {
            max = parseInt(item.rating_max, 10);
        } else {
            min = parseInt(item.scale_min, 10);
            max = parseInt(item.scale_max, 10);
        }
        if (Number.isNaN(min)) {
            min = 1;
        }
        if (Number.isNaN(max) || max <= min) {
            return [];
        }
        // The same ceiling `task_template._option_labels` puts on a scale: past
        // 20 points it is not a scale an examiner drew, and a runaway number
        // would render thousands of radio buttons.
        if (max - min > 20) {
            return [];
        }
        const points = [];
        for (let value = min; value <= max; value++) {
            points.push(String(value));
        }
        return points;
    }

    goldenOf(item) {
        return String((item && item.golden_answer) || "");
    }

    // ── annotation points ───────────────────────────────────────────────

    /**
     * The numbered points an annotation item asks about.
     *
     * The MARKERS WIN when the designer drew any: `_item_spec` reads the
     * numbers off `regions` and only falls back to `annotation_count`, so an
     * editor that offered the count as the authority would show five key boxes
     * for a plate carrying three markers and refuse to publish either way.
     */
    annotationNumbers(item) {
        const regions = Array.isArray(item?.regions) ? item.regions : [];
        const drawn = regions
            .map((region) => parseInt(region?.n, 10))
            .filter((n) => !Number.isNaN(n) && n > 0);
        if (drawn.length) {
            return [...new Set(drawn)].sort((a, b) => a - b);
        }
        const count = parseInt(item?.annotation_count, 10);
        if (Number.isNaN(count) || count <= 0) {
            return [];
        }
        return Array.from({ length: Math.min(count, 20) }, (_, i) => i + 1);
    }

    hasDrawnRegions(item) {
        return (Array.isArray(item?.regions) ? item.regions : []).some(
            (region) => parseInt(region?.n, 10) > 0
        );
    }

    goldenLabelOf(item, number) {
        const labels = (item && item.golden_labels) || {};
        return String(labels[String(number)] || "");
    }

    onGoldenLabel(sectionIndex, itemIndex, number, ev) {
        const text = ev.target.value;
        this.editItem(sectionIndex, itemIndex, (item) => {
            const labels =
                item.golden_labels && typeof item.golden_labels === "object"
                    ? item.golden_labels
                    : {};
            // KEYED BY THE STRING FORM of the number, because that is what
            // `_item_spec` looks up (`labels.get(str(n))`).
            labels[String(number)] = text;
            item.golden_labels = labels;
        });
    }

    // ── media ───────────────────────────────────────────────────────────

    /**
     * Whether to preview this url as a clip - FOR THE PREVIEW ONLY.
     *
     * The server decides for real (`_item_media_is_video`, which reads the
     * probed `media_kind` first and falls back to the url), and this must not
     * pretend otherwise: it exists so the panel draws a `<video>` for a clip
     * instead of a broken `<img>`. Deliberately the same order as the server:
     * the block kind, then the recorded kind, then the url.
     */
    isVideoUrl(item, field) {
        if (item?.kind === "videoBlock") {
            return true;
        }
        const url = String((item && item[field]) || "");
        const declared = String(item?.media_kind || "").toLowerCase();
        if (/^https?:\/\/(www\.|m\.|player\.)?(youtube\.com|youtu\.be|vimeo\.com)/i
            .test(url)) {
            return true;
        }
        if (declared === "video" || declared === "image") {
            return declared === "video";
        }
        return /\.(mp4|webm|mov)(\?|#|$)/i.test(url);
    }

    /** True for a url a `<video>`/`<img>` element cannot render inline. */
    isEmbedOnly(url) {
        return /^https?:\/\/(www\.|m\.)?(youtube\.com|youtu\.be|vimeo\.com)/i
            .test(String(url || ""));
    }

    mediaKey(sectionIndex, itemIndex, field) {
        return `${sectionIndex}:${itemIndex}:${field}`;
    }

    mediaBusy(sectionIndex, itemIndex, field) {
        return Boolean(
            this.state.mediaBusy[this.mediaKey(sectionIndex, itemIndex, field)]
        );
    }

    mediaError(sectionIndex, itemIndex, field) {
        return (
            this.state.mediaError[
                this.mediaKey(sectionIndex, itemIndex, field)
            ] || ""
        );
    }

    /**
     * POST to one of the designer's own media routes.
     *
     * `credentials: "same-origin"` and nothing else: these routes are
     * `auth="user"` with `csrf=False`, so the back-office session cookie is the
     * whole credential, and `require_manager` on the route is the same gate the
     * Flutter designer passes. The envelope is this API's own
     * `{"ok": bool, "data"|"error"}` - unwrapped here rather than trusted,
     * because a 413 or a 503 carries the message an operator has to read (the
     * S3 settings to fill in, the size limit, "share it as Anyone with the
     * link") and swallowing it would leave a dead plate with no explanation.
     */
    async postMedia(url, payload) {
        const response = await fetch(url, {
            method: "POST",
            credentials: "same-origin",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(payload),
        });
        let body = null;
        try {
            body = await response.json();
        } catch {
            body = null;
        }
        if (!response.ok || !body || body.ok !== true) {
            throw new Error(
                body?.error?.message ||
                    _t("The upload failed (HTTP %s).", response.status)
            );
        }
        return body.data || {};
    }

    async runMedia(sectionIndex, itemIndex, field, work) {
        const key = this.mediaKey(sectionIndex, itemIndex, field);
        this.state.mediaBusy[key] = true;
        this.state.mediaError[key] = "";
        try {
            await work();
        } catch (error) {
            this.state.mediaError[key] =
                error.message || _t("The upload failed.");
        } finally {
            this.state.mediaBusy[key] = false;
        }
    }

    onPickMedia(sectionIndex, itemIndex, field, ev) {
        const file = ev.target.files?.[0];
        // The input is cleared so picking the SAME file again still fires a
        // change event - a retry after a failed upload otherwise does nothing.
        ev.target.value = "";
        if (!file) {
            return;
        }
        return this.runMedia(sectionIndex, itemIndex, field, async () => {
            const data = await this.readBase64(file);
            const stored = await this.postMedia(MEDIA_UPLOAD_URL, {
                name: file.name,
                content_type: file.type || "application/octet-stream",
                data,
            });
            this.editItem(sectionIndex, itemIndex, (item) => {
                item[field] = stored.url || "";
                this.stampMediaKind(item, field, file.type);
            });
        });
    }

    /**
     * Copy a share link into this app's own storage.
     *
     * The route is the authority on which links can be imported - Drive,
     * Dropbox, OneDrive, SharePoint, each anchored on its whole host, because
     * that allow-list is the SSRF boundary of the whole feature. So this sends
     * whatever is in the box and shows what came back; guessing here which
     * links are importable would be a second, weaker copy of that list.
     */
    onImportMedia(sectionIndex, itemIndex, field) {
        const item = this.sections[sectionIndex]?.items?.[itemIndex];
        const url = String((item && item[field]) || "").trim();
        if (!url) {
            const key = this.mediaKey(sectionIndex, itemIndex, field);
            this.state.mediaError[key] = _t(
                "Paste the share link in the box first."
            );
            return;
        }
        return this.runMedia(sectionIndex, itemIndex, field, async () => {
            const stored = await this.postMedia(MEDIA_IMPORT_URL, { url });
            this.editItem(sectionIndex, itemIndex, (target) => {
                target[field] = stored.url || "";
                this.stampMediaKind(target, field, stored.content_type);
            });
        });
    }

    /**
     * Record whether this plate is a still or a clip.
     *
     * WHY IT MATTERS, and it is a bug that reached candidates: one Google Drive
     * link serves an image or a video with no way to tell from the string, so a
     * clip stored with no `media_kind` was filed under images and its bytes
     * fetched into the question's image field - a dead 0:00 player. Upload and
     * import both KNOW the content type, so the answer is recorded rather than
     * guessed. Only `media_url` carries it: the item has one `media_kind` field
     * and `_item_media_is_video` reads it for the first plate, so stamping it
     * from the second would describe the wrong file.
     */
    stampMediaKind(item, field, contentType) {
        if (field !== "media_url") {
            return;
        }
        const type = String(contentType || "").toLowerCase();
        if (type.startsWith("video/")) {
            item.media_kind = "video";
        } else if (type.startsWith("image/")) {
            item.media_kind = "image";
        }
    }

    /**
     * A file as base64, without the data: prefix.
     *
     * NO SIZE CHECK HERE ON PURPOSE. The route owns the limit (100 MB, checked
     * against the base64 length before it decodes anything) and answers a 413
     * naming it; a second copy of that number in the widget is a number that
     * can disagree with the server about what will be accepted.
     */
    readBase64(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () =>
                resolve(String(reader.result || "").split(",")[1] || "");
            reader.onerror = () =>
                reject(new Error(_t("That file could not be read.")));
            reader.readAsDataURL(file);
        });
    }

    onClearMedia(sectionIndex, itemIndex, field) {
        this.editItem(sectionIndex, itemIndex, (item) => {
            item[field] = "";
            if (field === "media_url") {
                // The recorded kind described the file that has just gone; left
                // behind it would classify whatever replaces it.
                delete item.media_kind;
            }
        });
    }
}

export const formItemEditor = {
    component: FormItemEditor,
    displayName: _t("Form item editor"),
    supportedTypes: ["json"],
    supportedOptions: [
        {
            label: _t("Skip the publish check (task templates)"),
            name: "skip_publish_check",
            type: "boolean",
        },
    ],
    extractProps: ({ options }) => ({
        skipPublishCheck: Boolean(options.skip_publish_check),
    }),
};

registry.category("fields").add("be_form_item_editor", formItemEditor);
