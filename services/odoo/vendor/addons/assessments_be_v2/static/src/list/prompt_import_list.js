/** @odoo-module **/
/*
 * "Import" in the Generators list's gear menu - the one place generators are
 * imported from in Odoo, as the app has one Import on its Generators page.
 *
 * A gear-menu item, not a list button: the list sets `import="0"`, so Odoo's
 * generic "Import records" does not sit beside it as a second, different
 * import.
 *
 * Shown only where the list itself allows creating: the server strips `create`
 * from the arch for a user without create rights, and the similar-projects
 * ranking list of the same model is `create="false"`.
 */
import { Component } from "@odoo/owl";
import { DropdownItem } from "@web/core/dropdown/dropdown_item";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { exprToBoolean } from "@web/core/utils/strings";
import { STATIC_ACTIONS_GROUP_NUMBER } from "@web/search/action_menus/action_menus";

export class GeneratorImportItem extends Component {
    static template = "assessments_be_v2.GeneratorImportItem";
    static components = { DropdownItem };
    static props = {};

    setup() {
        this.action = useService("action");
    }

    onImport() {
        this.action.doAction(
            "assessments_be_v2.action_assessments_be_generator_import",
            // The wizard closes itself on success; re-run the search so the
            // list shows the generators that just arrived.
            { onClose: () => this.env.searchModel.search() }
        );
    }
}

registry.category("cogMenu").add(
    "assessments-be-generator-import",
    {
        Component: GeneratorImportItem,
        groupNumber: STATIC_ACTIONS_GROUP_NUMBER,
        isDisplayed: ({ config, searchModel }) =>
            config.actionType === "ir.actions.act_window" &&
            config.viewType === "list" &&
            searchModel?.resModel === "assessments.be.prompt" &&
            exprToBoolean(config.viewArch?.getAttribute("create"), true),
    },
    { sequence: 1 }
);
