#!/bin/bash

# Check if running with no arguments and no stdin
if [[ $# -eq 0 && -t 0 ]]; then
    echo "Usage: $0 < input.json" >&2
    echo "Error: This script requires JSON input via stdin" >&2
    exit 1
fi

# Parse JSON input from stdin with timeout protection
input=""
if [[ ! -t 0 ]]; then
    input=$(timeout 5 cat) || {
        echo '{"status": "error", "message": "Failed to read input or timeout occurred"}' >&2
        exit 1
    }
fi

# Validate that we have input
if [[ -z "$input" ]]; then
    echo '{"status": "error", "message": "No input provided"}' >&2
    exit 1
fi
# echo INPUT $input;echo
# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo '{"status": "error", "message": "jq command not found - required for JSON processing"}' >&2
    exit 1
fi

# Parse JSON with error handling
check_only=$(echo "$input" | jq -r '.check_only // false' 2>/dev/null) || {
    echo '{"status": "error", "message": "Invalid JSON input"}' >&2
    exit 1
}

# Get files array - handle both object and array formats
files_config=$(echo "$input" | jq -c '.files' 2>/dev/null)
if [[ "$files_config" == "null" || -z "$files_config" ]]; then
    files_config="{}"
fi

# Initialize counters and arrays
files_checked=0
files_fixed=0
declare -a compliance_issues=()
declare -a details=()
overall_status="success"

# Function to check file compliance
check_file_compliance() {
    local file_path="$1"
    local required_mode="$2"
    local required_owner="$3"
    local required_group="$4"
    local required_content="$5"
    local content_source="$6"
    
    local -a issues=()
    local compliant=true
    
    # Check if file exists
    if [[ ! -f "$file_path" ]]; then
        issues+=("file_missing")
        compliant=false
        echo "false|${issues[*]}"
        return
    fi
    
    # Check permissions
    if [[ -n "$required_mode" ]]; then
        current_mode=$(stat -c "%a" "$file_path" 2>/dev/null)
        if [[ "$current_mode" != "$required_mode" ]]; then
            issues+=("mode_mismatch: current=$current_mode, required=$required_mode")
            compliant=false
        fi
    fi
    
    # Check owner
    if [[ -n "$required_owner" ]]; then
        current_owner=$(stat -c "%U" "$file_path" 2>/dev/null)
        if [[ "$current_owner" != "$required_owner" ]]; then
            issues+=("owner_mismatch: current=$current_owner, required=$required_owner")
            compliant=false
        fi
    fi
    
    # Check group
    if [[ -n "$required_group" ]]; then
        current_group=$(stat -c "%G" "$file_path" 2>/dev/null)
        if [[ "$current_group" != "$required_group" ]]; then
            issues+=("group_mismatch: current=$current_group, required=$required_group")
            compliant=false
        fi
    fi
    
    # Check content
    if [[ -n "$required_content" ]] || [[ -n "$content_source" && -f "$content_source" ]]; then
        local target_content="$required_content"
        
        if [[ -n "$content_source" && -f "$content_source" ]]; then
            target_content=$(cat "$content_source")
        fi
        
        if [[ -n "$target_content" ]]; then
            current_hash=$(sha256sum "$file_path" 2>/dev/null | cut -d' ' -f1)
            target_hash=$(echo "$target_content" | sha256sum | cut -d' ' -f1)
            
            if [[ "$current_hash" != "$target_hash" ]]; then
                issues+=("content_mismatch: content differs from requirement")
                compliant=false
            fi
        fi
    fi
    
    if [[ "$compliant" == true ]]; then
        echo "true|"
    else
        # Join issues with pipe separator
        local issues_str=$(IFS='|'; echo "${issues[*]}")
        echo "false|$issues_str"
    fi
}

# Function to fix file compliance
fix_file_compliance() {
    local file_path="$1"
    local required_mode="$2"
    local required_owner="$3"
    local required_group="$4"
    local required_content="$5"
    local content_source="$6"
    local issues="$7"
    
    local -a fixes_applied=()
    local success=true
    local error_msg=""
    
    # Create file if missing
    if [[ "$issues" == *"file_missing"* ]]; then
        if touch "$file_path" 2>/dev/null; then
            fixes_applied+=("created_file")
        else
            success=false
            error_msg="Failed to create file: $file_path"
        fi
    fi
    
    # Fix content first (if needed and file creation succeeded)
    if [[ "$success" == true && ("$issues" == *"content_mismatch"* || "$issues" == *"file_missing"*) ]]; then
        local target_content="$required_content"
        
        if [[ -n "$content_source" && -f "$content_source" ]]; then
            target_content=$(cat "$content_source")
        fi
        
        if [[ -n "$target_content" ]]; then
            if echo "$target_content" > "$file_path" 2>/dev/null; then
                if [[ "$issues" == *"content_mismatch"* ]]; then
                    fixes_applied+=("fixed_content")
                else
                    fixes_applied+=("wrote_content")
                fi
            else
                success=false
                error_msg="Failed to write content to file: $file_path"
            fi
        fi
    fi
    
    # Fix permissions
    if [[ "$success" == true && "$issues" == *"mode_mismatch"* && -n "$required_mode" ]]; then
        if chmod "$required_mode" "$file_path" 2>/dev/null; then
            fixes_applied+=("fixed_permissions")
        else
            success=false
            error_msg="Failed to set permissions on file: $file_path"
        fi
    fi
    
    # Fix owner and group
    if [[ "$success" == true && (-n "$required_owner" || -n "$required_group") ]]; then
        local chown_target=""
        
        if [[ -n "$required_owner" && -n "$required_group" ]]; then
            chown_target="$required_owner:$required_group"
        elif [[ -n "$required_owner" ]]; then
            chown_target="$required_owner"
        elif [[ -n "$required_group" ]]; then
            chown_target=":$required_group"
        fi
        
        if [[ -n "$chown_target" ]]; then
            if chown "$chown_target" "$file_path" 2>/dev/null; then
                [[ -n "$required_owner" ]] && fixes_applied+=("fixed_owner")
                [[ -n "$required_group" ]] && fixes_applied+=("fixed_group")
            else
                success=false
                error_msg="Failed to change ownership of file: $file_path"
            fi
        fi
    fi
    
    if [[ "$success" == true ]]; then
        local fixes_str=$(IFS=','; echo "${fixes_applied[*]}")
        echo "true|$fixes_str"
    else
        echo "false|$error_msg"
    fi
}

# Function to escape JSON strings
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n'
}
# Process each file configuration
if [[ "$files_config" == "{}" ]]; then
    # No files to process - output empty result
    echo '{"status": "success", "files_checked": 0, "files_fixed": 0, "compliance_issues": [], "details": []}'
    exit 0
fi

# Process each file in the configuration using process substitution to avoid subshell
while IFS= read -r file_entry; do
    [[ -z "$file_entry" ]] && continue
    
    # Extract file key and config
    file_key=$(echo "$file_entry" | jq -r '.key' 2>/dev/null)
    file_config=$(echo "$file_entry" | jq -c '.value' 2>/dev/null)
    
    file_path=$(echo "$file_config" | jq -r '.path // ""' 2>/dev/null)
    required_mode=$(echo "$file_config" | jq -r '.mode // ""' 2>/dev/null)
    required_owner=$(echo "$file_config" | jq -r '.owner // ""' 2>/dev/null)
    required_group=$(echo "$file_config" | jq -r '.group // ""' 2>/dev/null)
    required_content=$(echo "$file_config" | jq -r '.content // ""' 2>/dev/null)
    content_source=$(echo "$file_config" | jq -r '.content_source // ""' 2>/dev/null)
    
    # Skip if no file path specified
    [[ -z "$file_path" ]] && continue
    
    ((files_checked++))
    
    # Check compliance
    compliance_result=$(check_file_compliance "$file_path" "$required_mode" "$required_owner" "$required_group" "$required_content" "$content_source")
    compliant=$(echo "$compliance_result" | cut -d'|' -f1)
    issues=$(echo "$compliance_result" | cut -d'|' -f2-)
    
    if [[ "$compliant" == "true" ]]; then
        details+=("{\"file\":\"$file_path\",\"status\":\"compliant\",\"message\":\"File is compliant with requirements\"}")
    else
        # Convert issues string back to array for JSON
        IFS='|' read -ra issue_array <<< "$issues"
        issues_json=""
        for issue in "${issue_array[@]}"; do
            [[ -n "$issues_json" ]] && issues_json+=","
            issues_json+="\"$(escape_json "$issue")\""
        done
        
        compliance_issues+=("[$issues_json]")
        
        if [[ "$check_only" == "true" ]]; then
            details+=("{\"file\":\"$file_path\",\"status\":\"non_compliant\",\"issues\":[$issues_json],\"message\":\"File has compliance issues (check-only mode)\"}")
            overall_status="non_compliant"
        else
            # Try to fix the issues
            fix_result=$(fix_file_compliance "$file_path" "$required_mode" "$required_owner" "$required_group" "$required_content" "$content_source" "$issues")
            fix_success=$(echo "$fix_result" | cut -d'|' -f1)
            fix_details=$(echo "$fix_result" | cut -d'|' -f2-)
            
            if [[ "$fix_success" == "true" ]]; then
                ((files_fixed++))
                # Convert fixes to JSON array
                IFS=',' read -ra fixes_array <<< "$fix_details"
                fixes_json=""
                for fix in "${fixes_array[@]}"; do
                    [[ -n "$fixes_json" ]] && fixes_json+=","
                    fixes_json+="\"$(escape_json "$fix")\""
                done
                details+=("{\"file\":\"$file_path\",\"status\":\"fixed\",\"issues_fixed\":[$fixes_json],\"message\":\"File compliance issues fixed\"}")
            else
                details+=("{\"file\":\"$file_path\",\"status\":\"failed_to_fix\",\"error\":\"$(escape_json "$fix_details")\",\"message\":\"Failed to fix compliance issues\"}")
                overall_status="partial_failure"
            fi
        fi
    fi
done < <(echo "$files_config" | jq -r 'to_entries[] | @json' 2>/dev/null)

# Build JSON output
details_json=$(IFS=','; echo "${details[*]}")
issues_json=$(IFS=','; echo "${compliance_issues[*]}")

cat << EOF
{
  "status": "$overall_status",
  "files_checked": $files_checked,
  "files_fixed": $files_fixed,
  "compliance_issues": [$issues_json],
  "details": [$details_json]
}
EOF
