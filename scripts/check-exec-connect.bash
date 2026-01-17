#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Run command with timeout (bash native implementation)
# Usage: run_with_timeout <seconds> <command...>
run_with_timeout() {
    local timeout_seconds=$1
    shift
    local cmd=("$@")
    
    # Run command in background
    "${cmd[@]}" &
    local cmd_pid=$!
    
    # Start a timeout watcher in background
    (
        sleep "$timeout_seconds"
        kill -9 "$cmd_pid" 2>/dev/null
    ) &
    local watcher_pid=$!
    
    # Wait for command to finish
    wait "$cmd_pid" 2>/dev/null
    local exit_code=$?
    
    # Kill the watcher if command finished before timeout
    kill -9 "$watcher_pid" 2>/dev/null
    wait "$watcher_pid" 2>/dev/null
    
    return $exit_code
}

# Check if required commands are installed
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    local missing_deps=()
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        missing_deps+=("aws-cli")
        print_error "AWS CLI is not installed"
    else
        local aws_version=$(aws --version 2>&1)
        print_success "AWS CLI is installed: $aws_version"
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
        print_error "jq is not installed"
    else
        local jq_version=$(jq --version 2>&1)
        print_success "jq is installed: $jq_version"
    fi
    
    # Check Session Manager Plugin
    if ! command -v session-manager-plugin &> /dev/null; then
        missing_deps+=("session-manager-plugin")
        print_error "Session Manager Plugin is not installed"
        print_info "Install it from: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    else
        local ssm_version=$(session-manager-plugin --version 2>&1 || echo "version check failed")
        print_success "Session Manager Plugin is installed: $ssm_version"
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials are not configured or invalid"
        missing_deps+=("aws-credentials")
    else
        local identity=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
        # Mask AWS Account ID (12-digit number) for security
        local masked_identity=$(echo "$identity" | sed 's/:[0-9]\{12\}:/:************:/g')
        print_success "AWS credentials configured: $masked_identity"
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Please install the missing dependencies and try again."
        exit 1
    fi
    
    print_success "All prerequisites are satisfied!"
}

# Show usage
usage() {
    echo "Usage: $0 -c <cluster-name> [-r <region>] [-s <service-name>]"
    echo ""
    echo "Options:"
    echo "  -c, --cluster     ECS cluster name (required)"
    echo "  -r, --region      AWS region (optional, uses default if not specified)"
    echo "  -s, --service     ECS service name (optional, checks all services if not specified)"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -c my-cluster -r ap-northeast-1"
    echo "  $0 -c my-cluster -s my-service"
    exit 1
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--cluster)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            -r|--region)
                REGION="$2"
                shift 2
                ;;
            -s|--service)
                SERVICE_NAME="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    if [ -z "$CLUSTER_NAME" ]; then
        print_error "Cluster name is required"
        usage
    fi
}

# Build AWS CLI region flag
get_region_flag() {
    if [ -n "$REGION" ]; then
        echo "--region $REGION"
    fi
}

# Check ECS Exec for a specific task
check_task_exec() {
    local cluster=$1
    local task_arn=$2
    local task_id=$(echo "$task_arn" | awk -F'/' '{print $NF}')
    local region_flag=$(get_region_flag)
    
    print_info "Checking task: $task_id"
    
    # Get task details
    local task_details=$(aws ecs describe-tasks \
        --cluster "$cluster" \
        --tasks "$task_arn" \
        $region_flag \
        --query 'tasks[0]' \
        --output json 2>/dev/null)
    
    if [ -z "$task_details" ] || [ "$task_details" == "null" ]; then
        print_error "  Failed to get task details for: $task_id"
        return 1
    fi
    
    # Check if enableExecuteCommand is enabled
    local exec_enabled=$(echo "$task_details" | jq -r '.enableExecuteCommand // false')
    local last_status=$(echo "$task_details" | jq -r '.lastStatus')
    local task_definition=$(echo "$task_details" | jq -r '.taskDefinitionArn' | awk -F'/' '{print $NF}')
    
    echo "  Task Definition: $task_definition"
    echo "  Last Status: $last_status"
    echo "  Execute Command Enabled: $exec_enabled"
    
    if [ "$exec_enabled" != "true" ]; then
        print_warning "  ECS Exec is NOT enabled for this task"
        return 1
    fi
    
    # Get containers in the task (exclude ecs-service-connect sidecar containers)
    local containers=$(echo "$task_details" | jq -r '.containers[].name' | grep -v '^ecs-service-connect')
    
    if [ -z "$containers" ]; then
        print_warning "  No user containers found (only ecs-service-connect sidecar containers)"
        return 0
    fi
    
    for container in $containers; do
        echo "  Checking container: $container"
        
        # Check managed agents status
        local agent_status=$(echo "$task_details" | jq -r --arg name "$container" \
            '.containers[] | select(.name == $name) | .managedAgents[] | select(.name == "ExecuteCommandAgent") | .lastStatus')
        
        if [ -n "$agent_status" ]; then
            echo "    ExecuteCommandAgent Status: $agent_status"
            
            if [ "$agent_status" == "RUNNING" ]; then
                print_success "    Container '$container' is ready for ECS Exec"
                
                # Try a simple connectivity test
                print_info "    Testing ECS Exec connectivity..."
                
                # Use temp file to capture interactive output
                local tmp_output
                tmp_output=$(mktemp)
                
                # Run with script command to capture PTY output (handle macOS vs Linux syntax)
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    # macOS syntax: script -q output_file command
                    script -q "$tmp_output" aws ecs execute-command \
                        --cluster "$cluster" \
                        --task "$task_arn" \
                        --container "$container" \
                        --interactive \
                        --command "echo 'ECS Exec test successful'" \
                        $region_flag </dev/null || true
                else
                    # Linux syntax: script -q -c "command" output_file
                    script -q -c "aws ecs execute-command \
                        --cluster '$cluster' \
                        --task '$task_arn' \
                        --container '$container' \
                        --interactive \
                        --command \"echo 'ECS Exec test successful'\" \
                        $region_flag" "$tmp_output" </dev/null || true
                fi
                
                local test_output
                test_output=$(cat "$tmp_output" 2>/dev/null | tr -d '\r' || echo "")
                rm -f "$tmp_output"
                
                # Check if output contains success message
                if echo "$test_output" | grep -q "ECS Exec test successful"; then
                    print_success "    ECS Exec test passed for container '$container'"
                else
                    print_warning "    ECS Exec test failed for container '$container'"
                    # Show error message if present
                    local error_msg
                    error_msg=$(echo "$test_output" | grep -iE "error|exception|failed" | head -1)
                    if [ -n "$error_msg" ]; then
                        echo "    Error: $error_msg"
                    else
                        echo "    Output: $(echo "$test_output" | tail -3 | tr '\n' ' ')"
                    fi
                fi
            else
                print_warning "    ExecuteCommandAgent is not RUNNING for container '$container'"
            fi
        else
            print_warning "    No ExecuteCommandAgent found for container '$container'"
        fi
    done
    
    echo ""
}

# List and check all tasks in a service
check_service_tasks() {
    local cluster=$1
    local service=$2
    local region_flag=$(get_region_flag)
    
    print_info "Checking service: $service"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Get tasks for the service
    local task_arns=$(aws ecs list-tasks \
        --cluster "$cluster" \
        --service-name "$service" \
        $region_flag \
        --query 'taskArns[]' \
        --output text 2>/dev/null)
    
    if [ -z "$task_arns" ]; then
        print_warning "No running tasks found for service: $service"
        return
    fi
    
    for task_arn in $task_arns; do
        check_task_exec "$cluster" "$task_arn"
    done
}

# Main function
main() {
    print_info "══════════════ ECS Exec Connectivity Checker ══════════════"
    
    parse_args "$@"
    check_prerequisites
    
    local region_flag=$(get_region_flag)
    
    print_info "Cluster: $CLUSTER_NAME"
    if [ -n "$REGION" ]; then
        print_info "Region: $REGION"
    fi
    
    # Verify cluster exists
    if ! aws ecs describe-clusters --clusters "$CLUSTER_NAME" $region_flag --query 'clusters[0].clusterName' --output text &>/dev/null; then
        print_error "Cluster '$CLUSTER_NAME' not found or not accessible"
        exit 1
    fi
    
    if [ -n "$SERVICE_NAME" ]; then
        # Check specific service
        check_service_tasks "$CLUSTER_NAME" "$SERVICE_NAME"
    else
        # List all services and check each
        print_info "Discovering services in cluster..."
        
        local services=$(aws ecs list-services \
            --cluster "$CLUSTER_NAME" \
            $region_flag \
            --query 'serviceArns[]' \
            --output text 2>/dev/null)
        
        if [ -z "$services" ]; then
            print_warning "No services found in cluster: $CLUSTER_NAME"
            
            # Check for standalone tasks
            print_info "Checking for standalone tasks..."
            local standalone_tasks=$(aws ecs list-tasks \
                --cluster "$CLUSTER_NAME" \
                $region_flag \
                --query 'taskArns[]' \
                --output text 2>/dev/null)
            
            if [ -z "$standalone_tasks" ]; then
                print_warning "No tasks found in cluster: $CLUSTER_NAME"
                exit 0
            fi
            
            echo ""
            print_info "Found standalone tasks"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            for task_arn in $standalone_tasks; do
                check_task_exec "$CLUSTER_NAME" "$task_arn"
            done
        else
            for service_arn in $services; do
                local service_name=$(echo "$service_arn" | awk -F'/' '{print $NF}')
                echo ""
                check_service_tasks "$CLUSTER_NAME" "$service_name"
            done
        fi
    fi
    
    echo ""
    print_success "Check Complete"
    echo ""
}

# Run main function
main "$@"

