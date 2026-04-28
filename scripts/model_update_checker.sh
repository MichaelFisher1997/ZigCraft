#!/usr/bin/env bash

set -euo pipefail

source scripts/github_actions_common.sh

api_response() {
    curl -fsSL https://models.dev/api.json
}

cmd_fetch_models() {
    local model_id="${MODEL_ID:-minimax-coding-plan/MiniMax-M2.7}"
    local family_only="${FAMILY_ONLY:-true}"
    local response provider model exists current_last_updated current_release_date model_name provider_models

    write_output model_id "$model_id"
    write_output family_only "$family_only"

    response="$(api_response || true)"
    if [[ -z "$response" ]]; then
        write_output error "Failed to fetch models.dev API"
        exit 0
    fi

    provider="$(cut -d/ -f1 <<< "$model_id")"
    model="$(cut -d/ -f2 <<< "$model_id")"
    write_output provider "$provider"
    write_output model "$model"

    exists="$(jq -r ".\"${provider}\".models.\"${model}\" != null" <<< "$response")"
    if [[ "$exists" != "true" ]]; then
        write_output error "Model ${model_id} not found in models.dev"
        exit 0
    fi

    current_last_updated="$(jq -r ".\"${provider}\".models.\"${model}\".last_updated" <<< "$response")"
    current_release_date="$(jq -r ".\"${provider}\".models.\"${model}\".release_date" <<< "$response")"
    model_name="$(jq -r ".\"${provider}\".models.\"${model}\".name" <<< "$response")"
    provider_models="$(jq -r ".\"${provider}\".models | keys[]" <<< "$response")"

    write_output current_last_updated "$current_last_updated"
    write_output current_release_date "$current_release_date"
    write_output model_name "$model_name"
    write_output all_models "$provider_models"
}

cmd_analyze_family() {
    local response provider current_model family_only base_prefix family_models latest_model latest_release model release
    response="$(api_response)"
    provider="${PROVIDER:?PROVIDER is required}"
    current_model="${CURRENT_MODEL:?CURRENT_MODEL is required}"
    family_only="${FAMILY_ONLY:-true}"
    base_prefix="${current_model%%-[0-9.]*}-"

    write_output base_prefix "$base_prefix"
    family_models="$(jq -r ".\"${provider}\".models | to_entries[] | select(.key | startswith(\"${base_prefix}\")) | .key" <<< "$response" 2>/dev/null || true)"
    write_output family_models "$family_models"

    latest_model=""
    latest_release=""
    while IFS= read -r model; do
        [[ -n "$model" ]] || continue
        release="$(jq -r ".\"${provider}\".models.\"${model}\".release_date" <<< "$response")"
        if [[ -z "$latest_release" || "$(printf '%s\n' "$release" "$latest_release" | sort -r | head -1)" == "$release" ]]; then
            latest_release="$release"
            latest_model="$model"
        fi
    done <<< "$family_models"

    write_output latest_family_model "$latest_model"
    write_output latest_release_date "$latest_release"

    if [[ "$current_model" != "$latest_model" ]]; then
        write_output update_type family
        write_output new_model "$latest_model"
        write_output update_reason "Newer model variant ${latest_model} available (released ${latest_release})"
    fi
}

cmd_read_state() {
    local state_file=".github/model-tracker.json"
    local model_id="${MODEL_ID:?MODEL_ID is required}"

    if [[ -f "$state_file" ]]; then
        write_output tracked_model "$(jq -r '.tracked."'"$model_id"'" // empty' "$state_file")"
        write_output tracked_spec "$(jq -r '.specs."'"$model_id"'" // empty' "$state_file")"
    else
        write_output tracked_model ""
        write_output tracked_spec ""
    fi
}

cmd_check_update() {
    local current_model="${CURRENT_MODEL:?CURRENT_MODEL is required}"
    local latest_family_model="${LATEST_FAMILY_MODEL:-}"
    local current_spec="${CURRENT_SPEC:-}"
    local tracked_model="${TRACKED_MODEL:-}"
    local tracked_spec="${TRACKED_SPEC:-}"
    local provider="${PROVIDER:?PROVIDER is required}"
    local model_id="${MODEL_ID:?MODEL_ID is required}"
    local update_needed=false update_reason=""

    if [[ -n "$latest_family_model" && "$current_model" != "$latest_family_model" && "$tracked_model" != "$latest_family_model" ]]; then
        update_needed=true
        update_reason="Newer model in family: ${latest_family_model}"
        write_output update_type family
        write_output new_model_id "${provider}/${latest_family_model}"
    fi

    if [[ "$update_needed" == "false" && -n "$tracked_spec" && "$tracked_spec" != "$current_spec" ]]; then
        update_needed=true
        update_reason="Model spec updated: ${tracked_spec} -> ${current_spec}"
        write_output update_type spec
        write_output new_model_id "$model_id"
    fi

    if [[ -z "$tracked_model" && -z "$tracked_spec" ]]; then
        update_needed=true
        update_reason="Initial tracking of model"
        write_output update_type initial
        write_output new_model_id "$model_id"
    fi

    write_output update_needed "$update_needed"
    write_output update_reason "$update_reason"

    echo "=== Update Check Results ==="
    echo "Current model: ${current_model}"
    echo "Latest in family: ${latest_family_model}"
    echo "Tracked model: ${tracked_model:-none}"
    echo "Tracked spec: ${tracked_spec:-none}"
    echo "Update needed: ${update_needed}"
    echo "Reason: ${update_reason}"
}

cmd_update_tracker() {
    local state_file=".github/model-tracker.json"
    local model_id="${MODEL_ID:?MODEL_ID is required}"
    local current_spec="${CURRENT_SPEC:-}"
    local new_model_id="${NEW_MODEL_ID:-}"
    local current_date tmp

    current_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p .github

    if [[ -f "$state_file" ]]; then
        tmp="$(mktemp)"
        jq --arg model "$model_id" \
           --arg newmodel "$new_model_id" \
           --arg spec "$current_spec" \
           --arg date "$current_date" \
           '.tracked[$model] = $newmodel | .specs[$model] = $spec | .last_checked = $date' \
           "$state_file" > "$tmp"
        mv "$tmp" "$state_file"
    else
        printf '{"tracked": {"%s": "%s"}, "specs": {"%s": "%s"}, "last_checked": "%s"}' \
            "$model_id" "$new_model_id" "$model_id" "$current_spec" "$current_date" > "$state_file"
    fi

    cat "$state_file"
}

cmd_find_workflows() {
    local workflows
    workflows="$(grep -l 'minimax-coding-plan/MiniMax' .github/workflows/*.yml 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
    write_output workflows "$workflows"
    echo "Found: ${workflows}"
}

cmd_create_pr() {
    local current_model="${CURRENT_MODEL:?CURRENT_MODEL is required}"
    local new_model_id="${NEW_MODEL_ID:?NEW_MODEL_ID is required}"
    local update_reason="${UPDATE_REASON:-}"
    local update_type="${UPDATE_TYPE:-}"
    local workflows="${WORKFLOWS:-}"
    local new_model branch_name workflows_list pr_body_file escaped_model_id

    new_model="$(cut -d/ -f2 <<< "$new_model_id")"
    branch_name="model-update/${new_model_id//\//-}"

    echo "Creating branch: $branch_name"
    git checkout -b "$branch_name"
    echo "=== Update Summary ==="
    echo "Current: ${current_model}"
    echo "New: ${new_model}"
    echo "Type: ${update_type}"
    echo "Workflows: ${workflows}"

    escaped_model_id="$(printf '%s' "$new_model_id" | sed 's/[\\&|]/\\&/g')"

    for workflow in .github/workflows/*.yml; do
        if grep -q 'minimax-coding-plan/MiniMax' "$workflow"; then
            sed -i "s|minimax-coding-plan/MiniMax-[A-Za-z0-9.]*|${escaped_model_id}|g" "$workflow"
            echo "Updated: $workflow"
        fi
    done

    git diff --stat
    git add .github/model-tracker.json
    if [[ -n "$workflows" ]]; then
        for workflow in $(tr ',' ' ' <<< "$workflows"); do
            git add "$workflow"
        done
    fi

    git commit -m "chore: update model from ${current_model} to ${new_model}"
    git push -u origin "$branch_name"

    if [[ -n "$workflows" ]]; then
        workflows_list="$(tr ',' '\n' <<< "$workflows" | while read -r f; do echo "- \`$f\`"; done | tr '\n' ' ')"
    else
        workflows_list="(no workflow files found)"
    fi

    pr_body_file="$(mktemp)"
    printf '%s\n' \
        "## Model Update" \
        "" \
        "This PR updates the AI model used in our OpenCode workflows." \
        "" \
        "**Change:** ${update_reason}" \
        "" \
        "**Files updated:**" \
        "${workflows_list}" \
        "" \
        "**Verification:**" \
        "- [ ] Confirm model exists in models.dev" \
        "- [ ] Review updated workflow files" \
        "- [ ] Run tests if available" \
        "" \
        "---" \
        "Auto-generated by Model Update Checker workflow" > "$pr_body_file"

    gh pr create --base dev --title "model: Update to ${new_model}" --body-file "$pr_body_file"
    echo "PR created successfully"
}

case "${1:?subcommand required}" in
    fetch-models) cmd_fetch_models ;;
    analyze-family) cmd_analyze_family ;;
    read-state) cmd_read_state ;;
    check-update) cmd_check_update ;;
    update-tracker) cmd_update_tracker ;;
    find-workflows) cmd_find_workflows ;;
    create-pr) cmd_create_pr ;;
    *)
        printf 'error: unknown subcommand: %s\n' "$1" >&2
        exit 2
        ;;
esac
