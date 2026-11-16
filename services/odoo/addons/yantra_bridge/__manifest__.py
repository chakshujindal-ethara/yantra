{
    "name": "Yantra Bridge",
    "summary": "Odoo as the system of record for Yantra workers and money: worker record, eligibility push, "
    "pay-window vendor bills with TDS, client invoices from delivery manifests.",
    "version": "19.0.1.0.0",
    "category": "Services/Yantra",
    "license": "LGPL-3",
    "author": "Ethara",
    "depends": ["base", "account", "contacts"],
    "external_dependencies": {"python": ["requests"]},
    "data": [
        "security/security.xml",
        "security/ir.model.access.csv",
        "data/cron.xml",
        "views/settings_views.xml",
        "views/worker_views.xml",
        "views/pay_window_views.xml",
        "views/project_views.xml",
        "views/menus.xml",
    ],
    "installable": True,
    "application": True,
}
