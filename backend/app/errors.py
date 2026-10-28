"""One place that turns every failure into a response the phone can show.

The detail stays in the server log. The wearer sees a sentence, never a
stack trace, a file path, or a token.
"""

import logging
from typing import Any, Dict, List

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger("cadence")

SERVER_ERROR_MESSAGE = (
    "Something went wrong on our side. "
    "Your data is saved on the phone and will be sent again."
)

_STATUS_CODES = {
    status.HTTP_400_BAD_REQUEST: "bad_request",
    status.HTTP_401_UNAUTHORIZED: "unauthorized",
    status.HTTP_403_FORBIDDEN: "forbidden",
    status.HTTP_404_NOT_FOUND: "not_found",
    status.HTTP_409_CONFLICT: "conflict",
    422: "invalid_request",
    status.HTTP_429_TOO_MANY_REQUESTS: "too_many_requests",
}


def _plain_validation_message(error: Dict[str, Any]) -> str:
    kind = str(error.get("type", ""))
    message = str(error.get("msg", "This value is not valid."))
    if kind == "missing":
        return "This field is required."
    if kind.startswith("greater_than") or kind.startswith("less_than"):
        return message.replace("Input should be", "Must be")
    if kind == "string_too_short":
        return "This value is too short."
    if kind.startswith("literal_error") or kind == "enum":
        return "This is not one of the allowed values."
    return message.replace("Input should be", "Must be").replace("Value error, ", "")


def _problems(exc: RequestValidationError) -> List[Dict[str, str]]:
    problems: List[Dict[str, str]] = []
    for error in exc.errors():
        location = [str(part) for part in error.get("loc", []) if part not in ("body", "query", "path")]
        problems.append(
            {
                "field": ".".join(location) or "request",
                "message": _plain_validation_message(error),
            }
        )
    return problems


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(RequestValidationError)
    async def on_validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content={
                "error": "invalid_request",
                "message": "Some of the information sent was not valid.",
                "problems": _problems(exc),
            },
        )

    @app.exception_handler(StarletteHTTPException)
    async def on_http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        detail = exc.detail if isinstance(exc.detail, str) else "The request could not be completed."
        return JSONResponse(
            status_code=exc.status_code,
            content={
                "error": _STATUS_CODES.get(exc.status_code, "request_failed"),
                "message": detail,
            },
            headers=getattr(exc, "headers", None),
        )

    @app.exception_handler(Exception)
    async def on_unhandled_error(request: Request, exc: Exception) -> JSONResponse:
        logger.exception(
            "unhandled error on %s %s: %s", request.method, request.url.path, exc
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content={"error": "server_error", "message": SERVER_ERROR_MESSAGE},
        )
