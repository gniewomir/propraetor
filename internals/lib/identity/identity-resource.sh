#!/usr/bin/env bash
# Environment-scoped Identity resource / JWT audience (ADR-0057 / #253).
# Sourced by Identity gather and tests. Not an operator entrypoint.
#
# Public:
#   identity_resource_aud_for_slug SLUG
#     Print the Pocket ID resource URI and JWT aud for an Environment slug.
#
#   identity_resource_api_display_name_for_slug SLUG
#     Print a human display name for the Environment-scoped Pocket ID API row.

identity_resource_aud_for_slug() {
  local slug="${1:?identity_resource_aud_for_slug: Environment slug required}"
  if ! printf '%s' "${slug}" | grep -Eq '^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$'; then
    echo "identity_resource_aud_for_slug: invalid Environment slug: ${slug}" >&2
    return 1
  fi
  printf 'propreator:%s\n' "${slug}"
}

identity_resource_api_display_name_for_slug() {
  local slug="${1:?identity_resource_api_display_name_for_slug: Environment slug required}"
  identity_resource_aud_for_slug "${slug}" >/dev/null || return 1
  printf 'Propraetor %s\n' "${slug}"
}
