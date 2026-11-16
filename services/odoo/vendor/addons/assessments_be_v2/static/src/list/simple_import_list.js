/** @odoo-module **/
/*
 * An always-visible "Import" button beside "New", for the Tags list and the two
 * question lists (Question Bank, Pending Approvals).
 *
 * WHY A CUSTOM VIEW AND NOT A <header> BUTTON. A declarative header button only
 * appears once a row is SELECTED, because Odoo treats it as a batch action -
 * which is exactly backwards for importing, the one action you take when the
 * list is empty.
 *
 * THE ACTION IS HARDCODED IN EACH SUBCLASS, deliberately. Passing it as a prop
 * is not allowed: `ListController.props` is a closed schema
 * (`web/static/src/views/list/list_controller.js`), and Owl validates props, so
 * an extra key throws at mount in dev mode. Another list costs a small
 * subclass.
 */
import { registry } from "@web/core/registry";
import { listView } from "@web/views/list/list_view";
import { ListController } from "@web/views/list/list_controller";
import { useService } from "@web/core/utils/hooks";

export class TagImportListController extends ListController {
    setup() {
        super.setup();
        this.actionService = useService("action");
    }

    onImportCsv() {
        this.actionService.doAction(
            "assessments_be_v2.action_assessments_be_tag_import",
            {
                // Re-read on close: an import that created rows must not leave
                // the list showing what it looked like beforehand.
                onClose: () => this.model.root.load(),
            }
        );
    }
}

/**
 * The same Import for the Question Bank and Pending Approvals lists - the two
 * places the app offers it. CSV and harness JSON land in Pending Approvals as
 * drafts, whichever list the file was dropped on; a native bank export restores
 * straight into the bank.
 */
export class QuestionImportListController extends ListController {
    setup() {
        super.setup();
        this.actionService = useService("action");
    }

    onImportCsv() {
        this.actionService.doAction(
            "assessments_be_v2.action_assessments_be_bank_import",
            { onClose: () => this.model.root.load() }
        );
    }
}

registry.category("views").add("be_question_import_list", {
    ...listView,
    Controller: QuestionImportListController,
    buttonTemplate: "assessments_be_v2.SimpleImportListButtons",
});

registry.category("views").add("be_tag_import_list", {
    ...listView,
    Controller: TagImportListController,
    buttonTemplate: "assessments_be_v2.SimpleImportListButtons",
});
