/** @odoo-module **/
/*
 * Graphical annotation editor for an Image Labelling question.
 *
 * THE GAP THIS CLOSES. Correcting a generated labelling question in Odoo meant
 * editing `detections_json` by hand: a list of `box_2d` quadruples on Gemini's
 * 0-1000 grid, y-first. An operator who can see that marker 4 sits on the wrong
 * defect cannot fix it by typing coordinates, so in practice the box stayed
 * wrong and the candidate was graded against it. The Flutter console has had a
 * drawing surface for this since SNo 168; Odoo had none. This is that surface,
 * as a pure OWL field widget - there is no React/Vue anywhere in this project.
 *
 * IT OWNS NO GEOMETRY MATHS. Both directions of the box transform live on the
 * model (`question.as_studio_annotation_item` forward-inverse pair), and this
 * widget only ever speaks NORMALISED 0-1 fractions of the picture:
 *
 *     read   assessments.be.question.studio_annotation_editor_payload()
 *     write  assessments.be.question.apply_studio_annotation_item(item)
 *
 * `apply_studio_annotation_item` is the SAME method
 * /api/v1/bank/<id>/studio_item/save calls - not a copy of its behaviour. That
 * is deliberate and load-bearing: that method re-derives the marker set as
 * drawn-OR-keyed, rewrites `detections_json`, `label_boxes_json`,
 * `subjective_rubric_json` and `solution_json` from one source, trims the
 * behavioural key to the surviving markers, and re-burns the numbered overlay
 * the candidate is actually shown. A widget that wrote any of those fields
 * itself would be a second implementation of the answer key, and the two would
 * disagree the first time either changed.
 *
 * NORMALISED, NEVER PIXELS. Boxes are positioned in `%` inside a wrapper whose
 * height comes from the image itself, so the overlay is aligned by layout rather
 * than by a measurement that has to be recomputed. The form sheet resizes, the
 * Image Evaluation tab is revealed, the window is dragged narrow - the boxes
 * stay on their defects with no resize listener at all, and nothing stored ever
 * depends on the width it was drawn at.
 *
 * WHY IT IS BOUND TO `solution_json`. That field IS the golden-answer map this
 * editor authors, so the binding is honest and the form reloads the widget when
 * the key changes. The widget never writes through the field - the ORM call
 * above does - which is why the record stays undirty while you drag.
 */
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardFieldProps } from "@web/views/fields/standard_field_props";
import { _t } from "@web/core/l10n/translation";
import {
    Component,
    onWillStart,
    onWillUnmount,
    onWillUpdateProps,
    useRef,
    useState,
} from "@odoo/owl";

const MODEL = "assessments.be.question";

// A box thinner than this is not a region, it is a stray click. The server
// stores it happily (`box_2d` of zero area) and the candidate then sees a
// numbered badge on a 1px sliver, so the floor is enforced before it is drawn.
const MIN_SIDE = 0.01;

// Below this drag distance a pointerdown is a SELECT, not a draw. Without it,
// clicking the picture to deselect created an invisible marker every time, and
// the save then refused with "every point needs a golden answer" naming a box
// nobody could see.
const DRAW_THRESHOLD_PX = 6;

// One arrow press. 0.5% of the picture is fine-grained enough to seat a box on
// a defect and coarse enough that a keyboard user is not there all day.
const NUDGE = 0.005;

function clamp(v, lo, hi) {
    return Math.min(hi, Math.max(lo, v));
}

/** Fractions carry more precision than the 0-1000 grid can store; rounding
 *  here keeps the payload readable and cannot lose a pixel the server keeps. */
function round4(v) {
    return Math.round(v * 10000) / 10000;
}

export class EtpAnnotationEditor extends Component {
    static template = "assessments_be_v2.EtpAnnotationEditor";
    static props = { ...standardFieldProps };

    setup() {
        this.orm = useService("orm");
        this.notification = useService("notification");
        this.plateRef = useRef("plate");
        this.state = useState({
            // unsaved | loading | error | blocked | ready
            status: "loading",
            reason: "",
            error: "",
            mediaUrl: "",
            imageBroken: false,
            markers: [],
            markerCap: 0,
            unkeyed: 0,
            // Highest marker number this question has been seen to carry. See
            // `nextNumber`: it is a high-water mark, not `markers.length`,
            // because a number must never be REUSED for a different region.
            highWater: 0,
            selected: null,
            dirty: false,
            busy: false,
            problems: [],
            // Bumped on every (re)load so the label inputs are rebuilt as FRESH
            // DOM nodes. `t-att-value` compiles to setAttribute("value"), which
            // a browser ignores once the user has typed into the input (the
            // dirty-value flag), so Revert left the discarded text on screen
            // above the restored state. A changed t-key replaces the node
            // instead of patching it, which is the only reliable way back.
            generation: 0,
        });
        // Drag bookkeeping is deliberately NOT reactive: it changes on every
        // pointermove and nothing renders from it.
        this.drag = null;
        this._onPointerMove = this.onPointerMove.bind(this);
        this._onPointerUp = this.onPointerUp.bind(this);

        onWillStart(() => this.load());
        onWillUpdateProps((nextProps) => {
            // A different record in the same widget instance - the form's next/
            // previous pager, or a breadcrumb back into a sibling question. Not
            // reloading here left one question's boxes drawn over another
            // question's picture.
            if (nextProps.record.resId !== this.props.record.resId) {
                return this.load(nextProps.record.resId);
            }
        });
        onWillUnmount(() => this.endDrag());
    }

    // ── reading ────────────────────────────────────────────────────────────

    /**
     * Pull the editable marker set for this question.
     *
     * Failures are rendered INLINE with a Retry rather than re-thrown. An
     * uncaught RPC error here reaches Odoo's error service and replaces the
     * whole question form with a modal - on the one screen whose other tabs are
     * the operator's only way to repair the data that broke this call.
     */
    async load(resId = undefined) {
        const id = resId === undefined ? this.props.record.resId : resId;
        this.drag = null;
        this.state.problems = [];
        this.state.selected = null;
        this.state.dirty = false;
        this.state.imageBroken = false;
        if (!id) {
            this.state.status = "unsaved";
            return;
        }
        this.state.status = "loading";
        let payload;
        try {
            payload = await this.orm.call(
                MODEL, "studio_annotation_editor_payload", [[id]]
            );
        } catch (error) {
            this.state.status = "error";
            this.state.error =
                error?.data?.message || error?.message ||
                _t("The marker set could not be loaded.");
            return;
        }
        if (!payload || typeof payload !== "object") {
            // A method that answered with something other than the payload -
            // an override, a stale bundle, a proxy that rewrote the response.
            // Reading through it would throw inside onWillStart, and OWL
            // destroys the root component on that, taking the ENTIRE question
            // form down with it rather than one field.
            this.state.status = "error";
            this.state.error = _t("The marker set came back unreadable.");
            return;
        }
        this.state.mediaUrl = payload.media_url || "";
        this.state.markerCap = payload.marker_cap || 0;
        this.state.unkeyed = payload.unkeyed_markers || 0;
        this.state.reason = payload.reason || "";
        this.state.generation += 1;
        if (!payload.ok) {
            this.state.markers = [];
            this.state.status = "blocked";
            return;
        }
        // Plain copies, not the RPC result's own objects: these are mutated in
        // place by every drag and Revert restores from a fresh fetch.
        this.state.markers = (payload.markers || []).map((m) => ({
            n: m.n,
            label: m.label || "",
            drawable: !!m.drawable,
            x: m.drawable ? m.x : 0,
            y: m.drawable ? m.y : 0,
            w: m.drawable ? m.w : 0,
            h: m.drawable ? m.h : 0,
        }));
        // `annotation_count` is part of the floor because the markers this
        // editor can show are a SUBSET of the ones the stored key carries: the
        // count-only shape numbers them 1..N with no coordinates, and
        // `unkeyed_markers` are real numbers that never reach `markers` at all.
        // Without it, opening a question whose only showable marker is 4 and
        // deleting it would hand the next box the number 1 - which markers 1..3
        // in the stored key already mean.
        this.state.highWater = Math.max(
            payload.annotation_count || 0,
            ...this.state.markers.map((m) => m.n),
            0
        );
        this.state.status = "ready";
    }

    get drawableMarkers() {
        return this.state.markers.filter((m) => m.drawable);
    }

    /** Markers carried by the picture that this editor cannot redraw. The
     *  DOM-capture lane stores `box_px` - PIXELS on the original bitmap, not
     *  the normalised grid - so painting them would put a badge in the corner
     *  of the plate. Their LABEL is still editable, which is the whole reason
     *  they are listed at all. */
    get undrawableMarkers() {
        return this.state.markers.filter((m) => !m.drawable);
    }

    get blockedMessage() {
        switch (this.state.reason) {
            case "not_labelling":
                return _t(
                    "Only an Image Labelling question carries numbered boxes. " +
                    "Set Question Type to Image Labelling to mark a picture up."
                );
            case "no_image":
                return _t(
                    "No picture yet. Add the source image on the Single row " +
                    "under Image Evaluation, save, then come back to draw the " +
                    "boxes."
                );
            case "no_media":
                return _t(
                    "The Single image row carries neither an uploaded file nor " +
                    "a URL, so there is nothing to draw on yet."
                );
            default:
                return _t("This question has nothing to mark up.");
        }
    }

    get canAddMarker() {
        return !this.state.markerCap ||
            this.state.markers.length < this.state.markerCap;
    }

    get keyedCount() {
        return this.state.markers.filter((m) => (m.label || "").trim()).length;
    }

    markerAria(marker) {
        return marker.drawable
            ? _t("Ideal label for box %s", marker.n)
            : _t("Ideal label for marker %s (no coordinates stored)", marker.n);
    }

    boxAria(marker) {
        return _t(
            "Box %(n)s. Arrow keys move it, Shift with an arrow resizes it, " +
            "Delete removes it.",
            { n: marker.n }
        );
    }

    pct(value) {
        return `${round4(clamp(value, 0, 1) * 100)}%`;
    }

    // ── geometry, in fractions of the picture ───────────────────────────────

    /** Client pixels -> fraction of the plate. The plate wrapper is exactly the
     *  rendered image (the overlay is `inset: 0` inside it), so one rect serves
     *  both, at whatever width the form happens to be. */
    _fraction(ev) {
        const rect = this.plateRef.el?.getBoundingClientRect();
        if (!rect || !rect.width || !rect.height) {
            return null;
        }
        return {
            x: clamp((ev.clientX - rect.left) / rect.width, 0, 1),
            y: clamp((ev.clientY - rect.top) / rect.height, 0, 1),
            rect,
        };
    }

    /**
     * The number a NEW marker gets: one past the highest this question has been
     * seen to carry, NOT one past the highest still on screen.
     *
     * NEVER A RENUMBER, AND NEVER A REUSE. Marker numbers are stable for the
     * question's life because a submitted answer names them: delete marker 2 and
     * the set is {1, 3}, so the next box is 4 and marker 3 keeps meaning the
     * region the candidate described as 3. `_redraw_label_overlay` records the
     * measured failure from the other side - renumbering 1/3/5 to 1/2/3 painted
     * every badge against a different region than the key it was graded on.
     *
     * The high-water mark is the half that is easy to miss. Counting only the
     * markers still in `state.markers` looks equivalent and is not: delete every
     * box and the next one drawn becomes 1 again, silently rebinding a number a
     * candidate has already answered against to a completely different region.
     * That is the same damage as renumbering, arrived at by deleting instead.
     */
    nextNumber() {
        return Math.max(
            this.state.highWater,
            ...this.state.markers.map((m) => m.n),
            0
        ) + 1;
    }

    select(number) {
        this.state.selected = number;
    }

    markDirty() {
        this.state.dirty = true;
        this.state.problems = [];
    }

    // ── pointer: draw, move, resize ─────────────────────────────────────────

    onLayerPointerDown(ev) {
        if (this.state.busy || ev.button !== 0) {
            return;
        }
        const at = this._fraction(ev);
        if (!at) {
            return;
        }
        // Deferred creation: a pointerdown that never travels far enough is a
        // deselect, so the marker is only born once the pointer has moved.
        this.beginDrag(ev, {
            mode: "draw",
            originX: at.x,
            originY: at.y,
            created: false,
        });
        this.state.selected = null;
    }

    onBoxPointerDown(ev, number) {
        if (this.state.busy || ev.button !== 0) {
            return;
        }
        const marker = this.state.markers.find((m) => m.n === number);
        const at = this._fraction(ev);
        if (!marker || !at) {
            return;
        }
        this.select(number);
        this.beginDrag(ev, {
            mode: "move",
            number,
            grabX: at.x - marker.x,
            grabY: at.y - marker.y,
        });
    }

    onHandlePointerDown(ev, number) {
        if (this.state.busy || ev.button !== 0) {
            return;
        }
        this.select(number);
        this.beginDrag(ev, { mode: "resize", number });
    }

    /**
     * Arm a drag.
     *
     * The listeners go on the WINDOW, not the box: a pointer that leaves the
     * plate mid-drag (a box being dragged to the very edge of the picture, which
     * is exactly where a defect at the border needs it) stopped firing on the
     * element and left the box stuck to the cursor with no pointerup to release
     * it. `setPointerCapture` is not used because the draw lane has no element
     * to capture on until the marker exists.
     */
    beginDrag(ev, spec) {
        this.drag = { ...spec, startClientX: ev.clientX, startClientY: ev.clientY };
        window.addEventListener("pointermove", this._onPointerMove);
        window.addEventListener("pointerup", this._onPointerUp);
        window.addEventListener("pointercancel", this._onPointerUp);
    }

    endDrag() {
        this.drag = null;
        window.removeEventListener("pointermove", this._onPointerMove);
        window.removeEventListener("pointerup", this._onPointerUp);
        window.removeEventListener("pointercancel", this._onPointerUp);
    }

    onPointerMove(ev) {
        if (!this.drag) {
            return;
        }
        const at = this._fraction(ev);
        if (!at) {
            return;
        }
        if (this.drag.mode === "draw") {
            const travelled = Math.max(
                Math.abs(ev.clientX - this.drag.startClientX),
                Math.abs(ev.clientY - this.drag.startClientY)
            );
            if (!this.drag.created) {
                if (travelled < DRAW_THRESHOLD_PX) {
                    return;
                }
                if (!this.canAddMarker) {
                    this.notification.add(
                        _t(
                            "This question may carry at most %s marker(s). " +
                            "Delete one before drawing another.",
                            this.state.markerCap
                        ),
                        { type: "warning" }
                    );
                    this.endDrag();
                    return;
                }
                const number = this.nextNumber();
                this.state.markers.push({
                    n: number,
                    label: "",
                    drawable: true,
                    x: this.drag.originX,
                    y: this.drag.originY,
                    w: MIN_SIDE,
                    h: MIN_SIDE,
                });
                this.drag.created = true;
                this.drag.number = number;
                // Raise the water line here, not in `nextNumber`, so that
                // number is unavailable for the rest of the session even after
                // this box is deleted again.
                this.state.highWater = Math.max(this.state.highWater, number);
                this.select(number);
                this.markDirty();
            }
            this._stretch(this.drag.number, this.drag.originX,
                          this.drag.originY, at.x, at.y);
            return;
        }
        const marker = this.state.markers.find((m) => m.n === this.drag.number);
        if (!marker) {
            return;
        }
        if (this.drag.mode === "move") {
            marker.x = clamp(at.x - this.drag.grabX, 0, 1 - marker.w);
            marker.y = clamp(at.y - this.drag.grabY, 0, 1 - marker.h);
        } else {
            // Resize from the bottom-right handle: the top-left corner is the
            // anchor, so the box can never flip inside out.
            marker.w = clamp(at.x - marker.x, MIN_SIDE, 1 - marker.x);
            marker.h = clamp(at.y - marker.y, MIN_SIDE, 1 - marker.y);
        }
        this.markDirty();
    }

    /** Draw from an anchor corner to the pointer, in whichever direction the
     *  operator dragged - up-left is as valid as down-right. */
    _stretch(number, ax, ay, bx, by) {
        const marker = this.state.markers.find((m) => m.n === number);
        if (!marker) {
            return;
        }
        marker.x = Math.min(ax, bx);
        marker.y = Math.min(ay, by);
        marker.w = clamp(Math.abs(bx - ax), MIN_SIDE, 1 - marker.x);
        marker.h = clamp(Math.abs(by - ay), MIN_SIDE, 1 - marker.y);
    }

    onPointerUp() {
        this.endDrag();
    }

    // ── keyboard ───────────────────────────────────────────────────────────

    /**
     * Move, resize or delete the focused box without a mouse.
     *
     * A drag-only editor is unusable with a keyboard, and this screen is an
     * operator's day job. Each box is a focusable control, so Tab reaches it and
     * the arrows do the work a drag would. preventDefault only on the keys that
     * are handled, so Tab and Shift+Tab still leave the plate.
     */
    onBoxKeyDown(ev, number) {
        const marker = this.state.markers.find((m) => m.n === number);
        if (!marker || this.state.busy) {
            return;
        }
        if (ev.key === "Delete" || ev.key === "Backspace") {
            ev.preventDefault();
            this.onDelete(number);
            return;
        }
        const axis = {
            ArrowLeft: [-1, 0],
            ArrowRight: [1, 0],
            ArrowUp: [0, -1],
            ArrowDown: [0, 1],
        }[ev.key];
        if (!axis) {
            return;
        }
        ev.preventDefault();
        this.select(number);
        const [dx, dy] = axis;
        if (ev.shiftKey) {
            marker.w = clamp(marker.w + dx * NUDGE, MIN_SIDE, 1 - marker.x);
            marker.h = clamp(marker.h + dy * NUDGE, MIN_SIDE, 1 - marker.y);
        } else {
            marker.x = clamp(marker.x + dx * NUDGE, 0, 1 - marker.w);
            marker.y = clamp(marker.y + dy * NUDGE, 0, 1 - marker.h);
        }
        this.markDirty();
    }

    // ── editing the marker list ────────────────────────────────────────────

    onLabelInput(number, value) {
        const marker = this.state.markers.find((m) => m.n === number);
        if (marker) {
            marker.label = value;
            this.markDirty();
        }
    }

    onDelete(number) {
        this.state.markers = this.state.markers.filter((m) => m.n !== number);
        if (this.state.selected === number) {
            this.state.selected = null;
        }
        this.markDirty();
    }

    onRevert() {
        return this.load();
    }

    // ── saving ─────────────────────────────────────────────────────────────

    /**
     * The item `apply_studio_annotation_item` reads back.
     *
     * `title` and `help` are deliberately ABSENT. That method writes `name` and
     * `prompt` from them when they are non-empty, and the form already edits
     * both fields directly - sending them would let a stale copy held by this
     * widget overwrite a title the operator just retyped upstairs.
     */
    buildItem() {
        const golden = {};
        for (const marker of this.state.markers) {
            golden[String(marker.n)] = (marker.label || "").trim();
        }
        return {
            regions: this.drawableMarkers.map((m) => ({
                n: m.n,
                x: round4(m.x),
                y: round4(m.y),
                w: round4(m.w),
                h: round4(m.h),
            })),
            golden_labels: golden,
            annotation_count: this.state.markers.length,
        };
    }

    /**
     * The two refusals the server would make, made here first.
     *
     * Not a second implementation of the rule - the server still decides, and
     * its verdict is what is displayed when they disagree. This exists because
     * both refusals name a specific marker, and a round trip that comes back
     * saying "marker 5 has no golden answer" after the operator has already
     * left the field is a worse way to learn it than the input still being on
     * screen with a red ring round it.
     */
    localProblems() {
        if (!this.state.markers.length) {
            return [
                _t("Draw at least one box on the picture before saving."),
            ];
        }
        const missing = this.state.markers
            .filter((m) => !(m.label || "").trim())
            .map((m) => m.n);
        if (missing.length) {
            return [
                _t(
                    "Every marker needs an ideal label - what a correct " +
                    "description of it says. Missing: %s.",
                    missing.join(", ")
                ),
            ];
        }
        return [];
    }

    isUnkeyed(marker) {
        return !(marker.label || "").trim();
    }

    /**
     * Write the marker set back through the model method the API uses.
     *
     * THE FORM RECORD IS FLUSHED FIRST. `apply_studio_annotation_item` writes
     * the question and its image rows directly, and `solution_json` is one of
     * the fields it writes - so a form left dirty would push the browser's stale
     * copy of that field back over the key on the operator's next Save,
     * silently undoing the labels they just typed here.
     */
    async onSave() {
        const local = this.localProblems();
        if (local.length) {
            this.state.problems = local;
            return;
        }
        this.state.busy = true;
        this.state.problems = [];
        try {
            if (this.props.record.dirty) {
                const saved = await this.props.record.save();
                if (!saved) {
                    // The form refused (a required field, a constraint). It is
                    // already showing why; adding a second message here would
                    // just be noise.
                    return;
                }
            }
            const resId = this.props.record.resId;
            const refusals = await this.orm.call(
                MODEL, "apply_studio_annotation_item",
                [[resId], this.buildItem()]
            );
            if (refusals && refusals.length) {
                // A refusal is a whole-item rejection, never a partial write -
                // so nothing changed and the operator's edits must stay on
                // screen to be fixed rather than being reloaded away.
                this.state.problems = refusals;
                return;
            }
            // Reload BOTH: the record so the raw JSON under Advanced agrees with
            // what was just saved, and the payload so a re-burned overlay and
            // the server's own capping are what is on screen.
            await this.props.record.load();
            await this.load();
            this.notification.add(_t("Boxes and labels saved."), {
                type: "success",
            });
        } catch (error) {
            this.state.problems = [
                error?.data?.message || error?.message ||
                    _t("The marker set could not be saved."),
            ];
        } finally {
            this.state.busy = false;
        }
    }
}

export const etpAnnotationEditor = {
    component: EtpAnnotationEditor,
    displayName: _t("Annotation editor"),
    supportedTypes: ["text", "char"],
};

registry.category("fields").add("be_annotation_editor", etpAnnotationEditor);
