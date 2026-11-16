"""Domain errors carry an HTTP status and a stable code.
Services raise them; the app maps them once, at the boundary."""


class DomainError(Exception):
    status = 400
    code = "domain_error"

    def __init__(self, message: str, **context: object) -> None:
        super().__init__(message)
        self.message = message
        self.context = context

    def with_code(self, code: str) -> "DomainError":
        """A more specific code than the class default, for clients that branch on it."""
        self.code = code
        return self


class NotFound(DomainError):
    status = 404
    code = "not_found"


class Conflict(DomainError):
    status = 409
    code = "conflict"


class Forbidden(DomainError):
    status = 403
    code = "forbidden"


class Invalid(DomainError):
    status = 422
    code = "invalid"


class Unauthorized(DomainError):
    status = 401
    code = "unauthorized"
