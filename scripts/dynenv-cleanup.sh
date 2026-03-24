#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Capsules - Cleanup${NC}\n"

# Validate required env vars
for var in CLUSTER_NAME ENVIRONMENT_NAME MONK_CAPSULE_TOKEN MONK_SUBSCRIPTION_API_BASE MONK_AUTH_SERVICE_URL MONK_ORG_SLUG MONK_PROJECT_SLUG; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

AUTH_HEADER="Authorization: Bearer $MONK_CAPSULE_TOKEN"
CAPSULE_DELETE_RECORDS="${CAPSULE_DELETE_RECORDS:-false}"

# Mint a short-lived JIT CLI token from the capsule master token
mint_jit_token() {
    local perms="$1"
    local name="${2:-jit-$$}"
    local ttl="${3:-60}"
    if ! JIT_RESPONSE=$(curl -sf -X POST "$MONK_AUTH_SERVICE_URL/api-keys" \
        -H "Authorization: Bearer $MONK_CAPSULE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$name\",\"permissions\":$perms,\"expires_in_minutes\":$ttl}"); then
        printf "${RED}Error: Failed to mint JIT token${NC}\n" >&2
        return 1
    fi
    JIT_TOKEN=$(echo "$JIT_RESPONSE" | jq -r '.jwt // empty')
    if [ -z "$JIT_TOKEN" ]; then
        printf "${RED}Error: JIT token response did not include jwt${NC}\n" >&2
        return 1
    fi
    echo "$JIT_TOKEN"
}

# Configure Monk CLI for non-interactive CI usage
export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

printf "${GREEN}Cleaning up environment: $ENVIRONMENT_NAME (cluster: $CLUSTER_NAME, delete records: $CAPSULE_DELETE_RECORDS)${NC}\n"

# ============================================================================
# Step 1: Retrieve environment metadata from backend
# ============================================================================
printf "${GREEN}Retrieving environment metadata...${NC}\n"
HTTP_CODE=$(curl -s -o /tmp/env_response.json -w "%{http_code}" \
    "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME" \
    -H "$AUTH_HEADER")

if [ "$HTTP_CODE" = "404" ]; then
    printf "${YELLOW}Environment not found (already cleaned up). Exiting.${NC}\n"
    exit 0
fi

if [ "$HTTP_CODE" != "200" ]; then
    printf "${RED}Error: Failed to retrieve environment (HTTP $HTTP_CODE)${NC}\n"
    cat /tmp/env_response.json 2>/dev/null || true
    exit 1
fi

MONKCODE=$(jq -r '.cluster.monkcode // empty' /tmp/env_response.json)
CLUSTER_ID=$(jq -r '.cluster.clusterId // empty' /tmp/env_response.json)

# Best-effort: mark capsule metadata as down before deleting or deprovisioning.
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CAPSULE_DESTROY_PAYLOAD=$(jq -n \
    --arg branch "$ENVIRONMENT_NAME" \
    --arg status "destroyed" \
    --arg now "$NOW_UTC" \
    '{settings:{capsule:{source:"dynenv",branch:$branch,status:$status,lastDestroyedAt:$now,updatedAt:$now}}}')
curl -sf -X PATCH \
    "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$CAPSULE_DESTROY_PAYLOAD" > /dev/null 2>&1 || true

if [ -z "$MONKCODE" ]; then
    printf "${YELLOW}No cluster linked to environment. Cleaning up backend records only.${NC}\n"
else
    # ============================================================================
    # Step 2: Start local monkd, join cluster, then nuke
    # ============================================================================
    # We must go through a local monkd so that nuke can properly tear down all
    # remote nodes. Connecting directly via monkcode:// would leave the node we
    # happen to talk to dangling.
    printf "${GREEN}Minting JIT CLI token for cleanup...${NC}\n"
    CLI_PERMS="[\"manage:/projects/$MONK_PROJECT_SLUG/clusters/**\"]"
    MONK_JIT_CLI_TOKEN=$(mint_jit_token "$CLI_PERMS" "cleanup-$CLUSTER_NAME" 60)
    if [ -z "$MONK_JIT_CLI_TOKEN" ] || [ "$MONK_JIT_CLI_TOKEN" = "null" ]; then
        printf "${RED}Error: JIT CLI token mint returned empty${NC}\n"
        exit 1
    fi
    export MONK_SERVICE_TOKEN="$MONK_JIT_CLI_TOKEN"

    printf "${GREEN}Starting local Monk daemon...${NC}\n"
    monkd > /tmp/monkd.log 2>&1 &
    printf "${GREEN}Waiting for daemon to initialize (up to 60s)...${NC}\n"
    MONK_WAIT_ELAPSED=0
    while [ $MONK_WAIT_ELAPSED -lt 60 ]; do
        if monk --no-interactive --nofancy --nocolor --json version > /dev/null 2>&1; then
            printf "${GREEN}Daemon responded after ${MONK_WAIT_ELAPSED}s.${NC}\n"
            break
        fi
        sleep 2
        MONK_WAIT_ELAPSED=$((MONK_WAIT_ELAPSED + 2))
    done
    if [ $MONK_WAIT_ELAPSED -ge 60 ]; then
        printf "${RED}Daemon failed to start within 60s. Log:${NC}\n"
        cat /tmp/monkd.log 2>/dev/null || true
        exit 1
    fi
    sleep 5

    printf "${GREEN}Joining cluster via monkcode...${NC}\n"
    monk cluster join --monkcode "$MONKCODE" --local-name "cleanup-runner-$$"

    printf "${GREEN}Nuking cluster: $CLUSTER_NAME...${NC}\n"
    monk cluster nuke --force --remove-volumes --remove-snapshots
    printf "${GREEN}Cluster nuked.${NC}\n"
fi

# ============================================================================
# Step 3: Clean up backend records
# Delete cluster first (while it still has project_id for permission checks),
# then unlink from environment, then delete environment.
# ============================================================================
printf "${GREEN}Cleaning up backend records...${NC}\n"

# 3a. Delete cluster record
if [ -n "$CLUSTER_ID" ]; then
    printf "  Deleting cluster record...\n"
    curl -sf -X DELETE \
        "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/clusters/$CLUSTER_ID" \
        -H "$AUTH_HEADER" || printf "${YELLOW}  Warning: cluster record delete failed${NC}\n"
fi

# 3b. Unlink cluster from environment
printf "  Unlinking cluster from environment...\n"
curl -sf -X DELETE \
    "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME/cluster" \
    -H "$AUTH_HEADER" || printf "${YELLOW}  Warning: unlink failed (may already be unlinked)${NC}\n"


# 3c. Delete environment only for permanent cleanup
if [ "$CAPSULE_DELETE_RECORDS" = "true" ]; then
    printf "  Deleting environment...\n"
    curl -sf -X DELETE \
        "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME" \
        -H "$AUTH_HEADER" || printf "${YELLOW}  Warning: environment delete failed${NC}\n"
else
    printf "  Keeping environment record for future reprovision.\n"
fi

printf "${GREEN}Cleanup completed successfully.${NC}\n"
