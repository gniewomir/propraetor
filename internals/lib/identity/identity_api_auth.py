#!/usr/bin/env python3
"""API-side Bearer access-token authorization (ADR-0057 / #255).

Identity constrains issued token ``scope``; each API Workload must validate
that its mandatory marker permission key (``${workload-slug}:api``) is present
in ``scope`` after verifying JWT signature, ``iss``, ``aud``, and expiry.
"""

from __future__ import annotations

import os
import sys
from typing import Any

try:
    import jwt
    from jwt import PyJWKClient
except ImportError:  # pragma: no cover - exercised in container / optional unit gate
    jwt = None  # type: ignore[assignment]
    PyJWKClient = None  # type: ignore[assignment,misc]


class AuthorizationError(Exception):
    """Bearer token rejected at the API authorization boundary."""


_JWKS_CLIENTS: dict[str, Any] = {}


def _jwks_client(url: str) -> Any:
    if jwt is None or PyJWKClient is None:
        raise AuthorizationError("PyJWT is required for access-token validation")
    cached = _JWKS_CLIENTS.get(url)
    if cached is None:
        cached = PyJWKClient(url)
        _JWKS_CLIENTS[url] = cached
    return cached


def scopes_from_claims(claims: dict[str, Any]) -> set[str]:
    scope_raw = claims.get("scope")
    if scope_raw is None:
        scope_raw = claims.get("scp")
    if scope_raw is None:
        return set()
    if isinstance(scope_raw, list):
        return {str(item) for item in scope_raw if str(item)}
    return {part for part in str(scope_raw).split() if part}


def require_marker_in_scope(scopes: set[str], marker_key: str) -> None:
    if not marker_key:
        raise AuthorizationError("IDENTITY_MARKER_KEY must be configured")
    if marker_key not in scopes:
        raise AuthorizationError(
            f"token scope missing mandatory marker permission {marker_key!r}"
        )


def validate_access_token(
    token: str,
    *,
    issuer: str,
    jwks_url: str,
    audience: str,
    marker_key: str,
) -> dict[str, Any]:
    if not token:
        raise AuthorizationError("empty access token")
    if not issuer or not jwks_url or not audience:
        raise AuthorizationError("Identity resource-server binding is incomplete")

    client = _jwks_client(jwks_url)
    try:
        signing_key = client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256", "ES256", "EdDSA"],
            issuer=issuer,
            audience=audience,
            options={"require": ["exp", "iss", "aud"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise AuthorizationError("access token expired") from exc
    except jwt.InvalidTokenError as exc:
        raise AuthorizationError(f"invalid access token: {exc}") from exc

    require_marker_in_scope(scopes_from_claims(claims), marker_key)
    return claims


def authorize_bearer_header(
    authorization: str | None,
    *,
    issuer: str,
    jwks_url: str,
    audience: str,
    marker_key: str,
) -> dict[str, Any]:
    if not authorization:
        raise AuthorizationError("missing Authorization header")
    prefix = "Bearer "
    if not authorization.startswith(prefix):
        raise AuthorizationError("Authorization header must use Bearer scheme")
    token = authorization[len(prefix) :].strip()
    return validate_access_token(
        token,
        issuer=issuer,
        jwks_url=jwks_url,
        audience=audience,
        marker_key=marker_key,
    )


def authorize_from_env(authorization: str | None) -> dict[str, Any]:
    return authorize_bearer_header(
        authorization,
        issuer=os.environ.get("IDENTITY_ISSUER", ""),
        jwks_url=os.environ.get("IDENTITY_JWKS_URL", ""),
        audience=os.environ.get("IDENTITY_AUD", ""),
        marker_key=os.environ.get("IDENTITY_MARKER_KEY", ""),
    )


def _main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: identity-api-auth.py <jwt>")
    try:
        authorize_from_env(f"Bearer {sys.argv[1]}")
    except AuthorizationError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1) from exc
    print("ok")


if __name__ == "__main__":
    _main()
