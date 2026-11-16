{
    "name": "Yantra Assessment bridge",
    "version": "19.0.1.0.0",
    "summary": "Yantra workers into Assessment v2 without a second password: provisioning by Keycloak subject, "
    "one-time launch tickets, and invitations left to Yantra",
    "author": "Ethara",
    "license": "LGPL-3",
    "category": "Human Resources",
    "depends": ["assessments_be_v2", "api_auth_gateway"],
    "data": [
        "security/ir.model.access.csv",
        "data/service_user.xml",
    ],
    "external_dependencies": {"python": ["jwt"]},
    "installable": True,
}
