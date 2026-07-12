class LiquidStoolapError(Exception):
    def __init__(self, message: str, *, code: str | None = None, status_code: int | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.status_code = status_code


class TransportError(LiquidStoolapError):
    pass


class TimeoutError(TransportError):
    pass


class AuthenticationError(LiquidStoolapError):
    pass


class AuthorizationError(LiquidStoolapError):
    pass


class ValidationError(LiquidStoolapError):
    pass


class QueryError(LiquidStoolapError):
    pass


class ServerError(LiquidStoolapError):
    pass
