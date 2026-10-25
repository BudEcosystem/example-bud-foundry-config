#!/usr/bin/env bash
# scripts/gpu-foundry-keycloak-client.sh — create or update GPU Foundry's Keycloak client.
#
# WHY THIS EXISTS. The Keycloak chart applies realms with a KeycloakRealmImport, and the
# Keycloak operator imports with `--override=false`: a realm that already exists is skipped
# whole. So on an installation whose realm was imported before the GPU Foundry add-on, the
# `gpu-foundry-console` client in values/keycloak/values.gpu-foundry.yaml is never created, and
# sign-in fails with an unknown client. A new installation gets the client from its first import
# and does not need this; running it there is harmless.
#
# Run it once GPU Foundry has synced. Everything is read from the cluster, so it takes no input:
#   - the console's origin, the issuer (and so the realm) and the client id, from foundry-api;
#   - the client secret, from Secret foundry-oidc (rendered from secrets.<env>.yaml);
#   - Keycloak's admin credentials, from Secret keycloak-admin.
# Idempotent: it creates the client if missing and otherwise brings it to this definition, the
# same one values.gpu-foundry.yaml declares. Secrets are passed on stdin, never as arguments.
#
# Needs kubectl (pointed at the cluster) and jq.
#
#   scripts/gpu-foundry-keycloak-client.sh [--namespace gpu-foundry] [--keycloak-namespace keycloak]
set -euo pipefail

ns=gpu-foundry
kc_ns=keycloak
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) ns="$2"; shift 2 ;;
    --keycloak-namespace) kc_ns="$2"; shift 2 ;;
    *) echo "usage: $0 [--namespace gpu-foundry] [--keycloak-namespace keycloak]" >&2; exit 2 ;;
  esac
done
for tool in kubectl jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

env_of() { # NAME — a plain env value of foundry-api's first container
  kubectl -n "$ns" get deploy foundry-api -o json |
    jq -r --arg n "$1" '.spec.template.spec.containers[0].env[] | select(.name == $n) | .value // empty'
}
origin=$(env_of FOUNDRY_PUBLIC_ORIGIN)
issuer=$(env_of FOUNDRY_OIDC_ISSUER)
client_id=$(env_of FOUNDRY_OIDC_CLIENT_ID)
realm=${issuer##*/realms/}
[ -n "$origin" ] && [ -n "$client_id" ] && [ -n "$realm" ] && [ "$realm" != "$issuer" ] || {
  echo "could not read the origin, issuer and client id from deploy/foundry-api in $ns; has GPU Foundry synced?" >&2
  exit 1
}

secret=$(kubectl -n "$ns" get secret foundry-oidc -o jsonpath='{.data.client-secret}' | base64 -d)
admin_user=$(kubectl -n "$kc_ns" get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)
admin_pass=$(kubectl -n "$kc_ns" get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)
[ -n "$secret" ] && [ -n "$admin_user" ] && [ -n "$admin_pass" ] || {
  echo "Secret $ns/foundry-oidc or $kc_ns/keycloak-admin is missing a value" >&2
  exit 1
}
pod=$(kubectl -n "$kc_ns" get pods -l app=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$pod" ] || pod=keycloak-0

# The client, as values/keycloak/values.gpu-foundry.yaml declares it, with this estate's origin.
client=$(jq -cn --arg id "$client_id" --arg secret "$secret" --arg origin "$origin" '{
  clientId: $id, enabled: true, protocol: "openid-connect",
  publicClient: false, standardFlowEnabled: true, implicitFlowEnabled: false,
  directAccessGrantsEnabled: false, serviceAccountsEnabled: false,
  secret: $secret,
  redirectUris: [($origin + "/bff/callback")],
  webOrigins: [$origin],
  attributes: { "pkce.code.challenge.method": "S256", "post.logout.redirect.uris": ($origin + "/*") },
  protocolMappers: [{
    name: ("aud-" + $id), protocol: "openid-connect", protocolMapper: "oidc-audience-mapper",
    config: { "included.client.audience": $id, "access.token.claim": "true", "id.token.claim": "false" }
  }]
}')
# An update leaves the mappers alone: they are created with the client, and sending them again
# would add duplicates.
client_update=$(jq -c 'del(.protocolMappers)' <<<"$client")

printf '%s\n%s\n%s\n%s\n' "$admin_user" "$admin_pass" "$client" "$client_update" |
  kubectl -n "$kc_ns" exec -i "$pod" -- bash -c '
    set -eu
    read -r U; read -r P; read -r CLIENT; read -r CLIENT_UPDATE
    K=/opt/keycloak/bin/kcadm.sh; C=$(mktemp); trap "rm -f $C" EXIT
    ok=
    for server in http://localhost:8080 https://localhost:8443; do
      if $K config credentials --config "$C" --server "$server" --realm master --user "$U" --password "$P" >/dev/null 2>&1; then
        ok=1; break
      fi
    done
    [ -n "$ok" ] || { echo "could not log in to Keycloak as its admin" >&2; exit 1; }
    id=$($K get clients -r "'"$realm"'" -q clientId="'"$client_id"'" --fields id --format csv --noquotes --config "$C")
    if [ -z "$id" ]; then
      printf "%s" "$CLIENT" | $K create clients -r "'"$realm"'" -f - --config "$C" >/dev/null
      echo "created client '"$client_id"' in realm '"$realm"'"
    else
      printf "%s" "$CLIENT_UPDATE" | $K update "clients/$id" -r "'"$realm"'" -f - --config "$C"
      echo "updated client '"$client_id"' in realm '"$realm"'"
    fi
  '
