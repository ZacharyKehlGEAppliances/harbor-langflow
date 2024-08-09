#!/bin/bash

set -eo pipefail

# ========================================================================
# == Functions
# ========================================================================

show_version() {
    echo "Harbor CLI version: $version"
}

show_help() {
    show_version
    echo "Usage: $0 <command> [options]"
    echo
    echo "Compose Setup Commands:"
    echo "  up|u         - Start the containers"
    echo "  down|d       - Stop and remove the containers"
    echo "  restart|r    - Down then up"
    echo "  ps           - List the running containers"
    echo "  logs|l       - View the logs of the containers"
    echo "  exec         - Execute a command in a running service"
    echo "  pull         - Pull the latest images"
    echo "  dive         - Run the Dive CLI to inspect Docker images"
    echo "  run          - Run a one-off command in a service container"
    echo "  shell        - Load shell in the given service main container"
    echo "  build        - Build the given service"
    echo "  cmd <handle> - Print the docker-compose command"
    echo
    echo "Setup Management Commands:"
    echo "  ollama     - Run Ollama CLI (docker). Service should be running."
    echo "  smi        - Show NVIDIA GPU information"
    echo "  top        - Run nvtop to monitor GPU usage"
    echo "  llamacpp   - Configure llamacpp service"
    echo "  tgi        - Configure text-generation-inference service"
    echo "  litellm    - Configure LiteLLM service"
    echo "  openai     - Configure OpenAI API keys and URLs"
    echo "  vllm       - Configure VLLM service"
    echo "  aphrodite  - Configure Aphrodite service"
    echo "  tabbyapi   - Configure TabbyAPI service"
    echo "  mistralrs  - Configure mistral.rs service"
    echo "  cfd        - Run cloudflared CLI"
    echo
    echo "Service CLIs:"
    echo "  parllama          - Launch Parllama - TUI for chatting with Ollama models"
    echo "  plandex           - Launch Plandex CLI"
    echo "  interpreter|opint - Launch Open Interpreter CLI"
    echo "  fabric            - Run Fabric CLI"
    echo "  hf                - Run the Harbor's Hugging Face CLI. Expanded with a few additional commands."
    echo "    hf dl           - HuggingFaceModelDownloader CLI"
    echo "    hf parse-url    - Parse file URL from Hugging Face"
    echo "    hf token        - Get/set the Hugging Face Hub token"
    echo "    hf cache        - Get/set the path to Hugging Face cache"
    echo "    hf find <query> - Open HF Hub with a query (trending by default)"
    echo "    hf path <spec>  - Print a folder in HF cache for a given model spec"
    echo "    hf *            - Anything else is passed to the official Hugging Face CLI"
    echo
    echo "Harbor CLI Commands:"
    echo "  open handle                   - Open a service in the default browser"
    echo
    echo "  url <handle>                  - Get the URL for a service"
    echo "    url <handle>                         - Url on the local host"
    echo "    url [-a|--adressable|--lan] <handle> - (supposed) LAN URL"
    echo "    url [-i|--internal] <handle>         - URL within Harbor's docker network"
    echo
    echo "  qr  <handle>                  - Print a QR code for a service"
    echo
    echo "  t|tunnel <handle>             - Expose given service to the internet"
    echo "    tunnel down|stop|d|s        - Stop all running tunnels (including auto)"
    echo "  tunnels [ls|rm|add]           - Manage services that will be tunneled on 'up'"
    echo "    tunnels rm <handle|index>   - Remove, also accepts handle or index"
    echo "    tunnels add <handle>        - Add a service to the tunnel list"
    echo
    echo "  config [get|set|ls]           - Manage the Harbor environment configuration"
    echo "    config ls                   - All config values in ENV format"
    echo "    config get <field>          - Get a specific config value"
    echo "    config set <field> <value>  - Get a specific config value"
    echo "    config reset                - Reset Harbor configuration to default.env"
    echo
    echo "  defaults [ls|rm|add]          - List default services"
    echo "    defaults rm <handle|index>  - Remove, also accepts handle or index"
    echo "    defaults add <handle>       - Add"
    echo
    echo "  find <file>                   - Find a file in the caches visible to Harbor"
    echo "  ls|list [--active|-a]         - List available/active Harbor services"
    echo "  ln|link [--short]             - Create a symlink to the CLI, --short for 'h' link"
    echo "  unlink                        - Remove CLI symlinks"
    echo "  eject                         - Eject the Compose configuration, accepts same options as 'up'"
    echo "  help|--help|-h                - Show this help message"
    echo "  version|--version|-v          - Show the CLI version"
    echo "  gum                           - Run the Gum terminal commands"
    echo "  fixfs                         - Fix file system ACLs for service volumes"
    echo "  info                          - Show system information for debug/issues"
    echo "  update [-l|--latest]          - Update Harbor. --latest for the dev version"
}

# shellcheck disable=SC2034
__anchor_fns=true

resolve_compose_files() {
    # Find all .yml files in the specified base directory,
    # but do not go into subdirectories
    find "$base_dir" -maxdepth 1 -name "*.yml" |
    # For each file, count the number of dots in the filename
    # and prepend this count to the filename
    awk -F. '{print NF-1, $0}' |
    # Sort the files based on the
    # number of dots, in ascending order
    sort -n |
    # Remove the dot count, leaving
    # just the sorted filenames
    cut -d' ' -f2-
}

compose_with_options() {
    local base_dir="$PWD"
    local compose_files=("$base_dir/compose.yml")  # Always include the base compose file
    local options=("${default_options[@]}")

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dir=*)
                base_dir="${1#*=}"
                shift
                ;;
            *)
                options+=("$1")
                shift
                ;;
        esac
    done

    # Check for NVIDIA GPU and drivers
    if command -v nvidia-smi &> /dev/null && docker info | grep -q "Runtimes:.*nvidia"; then
        options+=("nvidia")
    fi

    for file in $(resolve_compose_files); do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            local match=false

            # This is a "cross" file, only to be included
            # if we're running all the mentioned services
            if [[ $filename == *".x."* ]]; then
                local cross="${filename#compose.x.}"
                cross="${cross%.yml}"

                # Convert dot notation to array
                local filename_parts=(${cross//./ })
                local all_matched=true

                for part in "${filename_parts[@]}"; do
                    if [[ ! " ${options[*]} " =~ " ${part} " ]]; then
                        all_matched=false
                        break
                    fi
                done

                if $all_matched; then
                    compose_files+=("$file")
                fi

                # Either way, the processing
                # for this file is done
                continue
            fi

            # Check if file matches any of the options
            for option in "${options[@]}"; do
                # echo "CHECK: $option"

                if [[ $option == "*" ]]; then
                    match=true
                    break
                fi

                if [[ $filename == *".$option."* ]]; then
                    match=true
                    break
                fi
            done

            # Include the file if:
            # 1. It matches an option and is not an NVIDIA file
            # 2. It matches an option, is an NVIDIA file, and NVIDIA is supported
            # if $match && (! $is_nvidia_file || ($is_nvidia_file && $has_nvidia)); then
            if $match ; then
                compose_files+=("$file")
            fi
        fi
    done

    # Prepare docker compose command
    local cmd="docker compose"
    for file in "${compose_files[@]}"; do
        cmd+=" -f $file"
    done

    # Return the command string
    echo "$cmd"
}

resolve_compose_command() {
    local is_human=false

    case "$1" in
        --human|-h)
            shift
            is_human=true
            ;;
    esac

    local cmd=$(compose_with_options "$@")

    if $is_human; then
        echo "$cmd" | sed "s|-f $harbor_home/|\n - |g"
    else
        echo "$cmd"
    fi
}

harbor_up() {
    $(compose_with_options "$@") up -d --wait

    if [ "$default_autoopen" = "true" ]; then
        open_service "$default_open"
    fi

    for service in "${default_tunnels[@]}"; do
        establish_tunnel "$service"
    done
}

run_hf_open() {
    local search_term="${*// /+}"
    local hf_url="https://huggingface.co/models?sort=trending&search=${search_term}"

    sys_open "$hf_url"
}

link_cli() {
    local target_dir=$(eval echo "$(env_manager get cli.path)")
    local script_name=$(env_manager get cli.name)
    local short_name=$(env_manager get cli.short)
    local script_path="$harbor_home/harbor.sh"
    local create_short_link=false

    # Check for "--short" flag
    for arg in "$@"; do
        if [[ "$arg" == "--short" ]]; then
            create_short_link=true
            break
        fi
    done

    # Determine which shell configuration file to update
    local shell_profile=""
    if [[ -f "$HOME/.zshrc" ]]; then
        shell_profile="$HOME/.zshrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
        shell_profile="$HOME/.bash_profile"
    elif [[ -f "$HOME/.bashrc" ]]; then
        shell_profile="$HOME/.bashrc"
    elif [[ -f "$HOME/.profile" ]]; then
        shell_profile="$HOME/.profile"
    else
        if [[ "$OSTYPE" == "darwin"* ]]; then
            shell_profile="$HOME/.zshrc"
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            shell_profile="$HOME/.bashrc"
        else
            # We can't determine the shell profile
            echo "Sorry, but Harbor can't determine which shell configuration file to update."
            echo "Please link the CLI manually."
            echo "Harbor supports: ~/.zshrc, ~/.bash_profile, ~/.bashrc, ~/.profile"
            return 1
        fi
    fi

    # Check if target directory exists in PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -q "$target_dir"; then
        echo "Creating $target_dir and adding it to PATH..."
        mkdir -p "$target_dir"

        # Update the shell configuration file
        echo -e "\nexport PATH=\"\$PATH:$target_dir\"\n" >> "$shell_profile"
        export PATH="$PATH:$target_dir"
        echo "Updated $shell_profile with new PATH."
    fi

    # Create symlink
    if ln -s "$script_path" "$target_dir/$script_name"; then
        echo "Symlink created: $target_dir/$script_name -> $script_path"
    else
        echo "Failed to create symlink. Please check permissions and try again."
        return 1
    fi

    # Create short symlink if "--short" flag is present
    if $create_short_link; then
        if ln -s "$script_path" "$target_dir/$short_name"; then
            echo "Short symlink created: $target_dir/$short_name -> $script_path"
        else
            echo "Failed to create short symlink. Please check permissions and try again."
            return 1
        fi
    fi

    echo "You may need to reload your shell or run 'source $shell_profile' for changes to take effect."
}

unlink_cli() {
    local target_dir=$(eval echo "$(env_manager get cli.path)")
    local script_name=$(env_manager get cli.name)
    local short_name=$(env_manager get cli.short)

    echo "Removing symlinks..."

    # Remove the main symlink
    if [ -L "$target_dir/$script_name" ]; then
        rm "$target_dir/$script_name"
        echo "Removed symlink: $target_dir/$script_name"
    else
        echo "Main symlink does not exist or is not a symbolic link."
    fi

    # Remove the short symlink
    if [ -L "$target_dir/$short_name" ]; then
        rm "$target_dir/$short_name"
        echo "Removed short symlink: $target_dir/$short_name"
    else
        echo "Short symlink does not exist or is not a symbolic link."
    fi
}

get_container_name() {
    local service_name="$1"
    local container_name="$default_container_prefix.$service_name"
    echo "$container_name"
}

get_service_port() {
    local services
    local target_name
    local port

    # Get list of running services
    services=$(docker compose ps --services --filter "status=running")

    # Check if any services are running
    if [ -z "$services" ]; then
        echo "No services are currently running."
        return 1
    fi

    service_name="$1"
    target_name=$(get_container_name "$1")

    # Check if the specified service is running
    if ! echo "$services" | grep -q "$service_name"; then
        echo "Service '$1' is not currently running."
        echo "Running services:"
        echo "$services"
        return 1
    fi

    # Get the port mapping for the service
    if port=$(docker port "$target_name" | perl -nle 'print m{0.0.0.0:\K\d+}g' | head -n 1); then
        echo "$port"
    else
        echo "No port mapping found for service '$1': $port"
        return 1
    fi
}

get_service_url() {
    local service_name="$1"
    local port

    if port=$(get_service_port "$service_name"); then
        echo "http://localhost:$port"
        return 0
    else
        echo "Failed to get port for service '$service_name':"
        echo "$port"
        return 1
    fi
}

get_adressable_url() {
    local service_name="$1"
    local port
    local ip_address

    if port=$(get_service_port "$service_name"); then
        if ip_address=$(get_ip); then
            echo "http://$ip_address:$port"
            return 0
        else
            echo "Failed to get IP address:"
            echo "$ip_address"
            return 1
        fi
    else
        echo "Failed to get port for service '$service_name':"
        echo "$port"
        return 1
    fi
}

get_intra_url() {
    local service_name="$1"
    local container_name
    local intra_host
    local intra_port

    container_name=$(get_container_name "$service_name")
    intra_host=$container_name

    if intra_port=$(docker port $container_name | awk -F'[ /]' '{print $1}' | sort -n | uniq); then
        echo "http://$intra_host:$intra_port"
        return 0
    else
        echo "Failed to get internal port for service '$service_name'"
        return 1
    fi
}

get_url() {
    local is_local=true
    local is_adressable=false
    local is_intra=false

    local filtered_args=()
    local arg

    for arg in "$@"; do
        case "$arg" in
            --intra|-i|--internal)
                is_local=false
                is_adressable=false
                is_intra=true
                ;;
            --addressable|-a|--lan)
                is_local=false
                is_intra=false
                is_adressable=true
                ;;
            *)
                filtered_args+=("$arg") # Add to filtered arguments
                ;;
        esac
    done

    # If nothing specified - use a handle
    # of the default service to open
    if [ ${#filtered_args[@]} -eq 0 ] || [ -z "${filtered_args[0]}" ]; then
        filtered_args[0]="$default_open"
    fi

    if $is_local; then
        get_service_url "${filtered_args[@]}"
    elif $is_adressable; then
        get_adressable_url "${filtered_args[@]}"
    elif $is_intra; then
        get_intra_url "${filtered_args[@]}"
    fi
}

print_qr() {
    local url="$1"
    $(compose_with_options "qrgen") run --rm qrgen "$url"
}

print_service_qr() {
    local url=$(get_url -a "$1")
    echo "URL: $url"
    print_qr "$url"
}

sys_info() {
    show_version
    echo "=========================="
    get_services -a
    echo "=========================="
    docker info
}

sys_open() {
    url=$1

    # Open the URL in the default browser
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url"  # Linux
    elif command -v open &> /dev/null; then
        open "$url"  # macOS
    elif command -v start &> /dev/null; then
        start "$url"  # Windows
    else
        echo "Unable to open browser. Please visit $url manually."
        return 1
    fi
}

open_service() {
    local service_url

    if service_url=$(get_url "$1"); then
        sys_open "$service_url"
        echo "Opened $service_url in your default browser."
    else
        echo "Failed to get service URL for $1:"
        echo "$service_url"
        return 1
    fi
}

smi() {
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi
    else
        echo "nvidia-smi not found."
    fi
}

nvidia_top() {
    if command -v nvtop &> /dev/null; then
        nvtop
    else
        echo "nvtop not found."
    fi
}

eject() {
    $(compose_with_options "$@") config
}

run_in_service() {
    local service_name="$1"
    shift
    local command_to_run="$@"

    if docker compose ps --services --filter "status=running" | grep -q "^${service_name}$"; then
        echo "Service ${service_name} is running. Executing command..."
        # shellcheck disable=SC2086
        docker compose exec ${service_name} ${command_to_run}
    else
        echo "Harbor ${service_name} is not running. Please start it with 'harbor up ${service_name}' first."
    fi
}

ensure_env_file() {
    local src_file="default.env"
    local tgt_file=".env"

    if [ ! -f "$tgt_file" ]; then
        echo "Creating .env file..."
        cp "$src_file" "$tgt_file"
    fi
}

reset_env_file() {
    echo "Resetting Harbor configuration..."
    rm .env
    ensure_env_file
}

execute_and_process() {
    local command_to_execute="$1"
    local success_command="$2"
    local error_message="$3"

    # Execute the command and capture its output
    command_output=$(eval "$command_to_execute" 2>&1)
    exit_code=$?

    # Check the exit code
    if [ $exit_code -eq 0 ]; then
        # Replace placeholder with command output, using | as delimiter
        success_command_modified=$(echo "$success_command" | sed "s|{{output}}|$command_output|")
        # If the command succeeded, pass the output to the success command
        eval "$success_command_modified"
    else
        # If the command failed, print the custom error message and the output
        echo "$error_message Exit code: $exit_code. Output:"
        echo "$command_output"
    fi
}

swap_and_retry() {
    local command=$1
    shift
    local args=("$@")

    # Try original order
    if "$command" "${args[@]}"; then
        return 0
    else
        local exit_code=$?

        # If failed and there are at least two arguments, try swapped order
        if [ $exit_code -eq $scramble_exit_code ] && [ ${#args[@]} -ge 2 ]; then
            echo "'harbor ${args[0]} ${args[1]}' failed, trying 'harbor ${args[1]} ${args[0]}'..."
            if "$command" "${args[1]}" "${args[0]}" "${args[@]:2}"; then
                return 0
            else
                # Check for common user-caused exit codes
                exit_code=$?

                # Check common exit codes
                case $exit_code in
                    0)
                        echo "Process completed successfully"
                        ;;
                    1)
                        echo "General error occurred"
                        ;;
                    2)
                        echo "Misuse of shell builtin"
                        ;;
                    126)
                        echo "Command invoked cannot execute (permission problem or not executable)"
                        ;;
                    127)
                        echo "Command not found"
                        ;;
                    128)
                        echo "Invalid exit argument"
                        ;;
                    129)
                        echo "SIGHUP (Hangup) received"
                        ;;
                    130)
                        echo "SIGINT (Keyboard interrupt) received"
                        ;;
                    131)
                        echo "SIGQUIT (Keyboard quit) received"
                        ;;
                    137)
                        echo "SIGKILL (Kill signal) received"
                        ;;
                    143)
                        echo "SIGTERM (Termination signal) received"
                        ;;
                    42)
                        # This is our own scrambler code, no need to print it
                        return 1
                        ;;
                    *)
                        echo "Exit code: $exit_code"
                        return 1
                        ;;
                esac
            fi
        fi
    fi
}

# shellcheck disable=SC2034
__anchor_envm=true

env_manager() {
    local env_file=".env"
    local prefix="HARBOR_"

    case "$1" in
        get)
            if [[ -z "$2" ]]; then
                echo "Usage: env_manager get <key>"
                return 1
            fi
            local upper_key=$(echo "$2" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
            value=$(grep "^$prefix$upper_key=" "$env_file" | cut -d '=' -f2-)
            value="${value#\"}"  # Remove leading quote if present
            value="${value%\"}"  # Remove trailing quote if present
            echo "$value"
            ;;
        set)
            if [[ -z "$2" ]]; then
                echo "Usage: env_manager set <key> <value>"
                return 1
            fi

            local upper_key=$(echo "$2" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
            shift 2  # Remove 'set' and the key from the arguments
            local value="$*"  # Capture all remaining arguments as the value

            if grep -q "^$prefix$upper_key=" "$env_file"; then
                sed -i "s|^$prefix$upper_key=.*|$prefix$upper_key=\"$value\"|" "$env_file"
            else
                echo "$prefix$upper_key=\"$value\"" >> "$env_file"
            fi
            echo "Set $prefix$upper_key to: \"$value\""
            ;;
        list|ls)
            grep "^$prefix" "$env_file" | sed "s/^$prefix//" | while read -r line; do
                key=${line%%=*}
                value=${line#*=}
                value=$(echo "$value" | sed -E 's/^"(.*)"$/\1/')  # Remove surrounding quotes for display
                printf "%-30s %s\n" "$key" "$value"
            done
            ;;
        reset)
            shift
            run_gum confirm "Are you sure you want to reset Harbor configuration?" && reset_env_file || echo "Reset cancelled"
            ;;
        *)
            echo "Usage: harbor config {get|set|ls|reset} [key] [value]"
            return $scramble_exit_code
            ;;
    esac
}

env_manager_alias() {
    local field=$1
    shift
    local get_command=""
    local set_command=""

    # Check if optional commands are provided
    if [[ "$1" == "--on-get" ]]; then
        get_command="$2"
        shift 2
    fi
    if [[ "$1" == "--on-set" ]]; then
        set_command="$2"
        shift 2
    fi

    case $1 in
        --help|-h)
            echo "Harbor config: $field"
            echo
            echo "This field is a string, use the following actions to manage it:"
            echo
            echo "  no arguments  - Get the current value"
            echo "  <value>       - Set a new value"
            echo
            return 0
            ;;
    esac

    if [ $# -eq 0 ]; then
        env_manager get "$field"
        if [ -n "$get_command" ]; then
            eval "$get_command"
        fi
    else
        env_manager set "$field" "$@"
        if [ -n "$set_command" ]; then
            eval "$set_command"
        fi
    fi
}

env_manager_arr() {
    local field=$1
    shift
    local delimiter=";"
    local get_command=""
    local set_command=""
    local add_command=""
    local remove_command=""

    case "$1" in
        --help|-h)
            echo "Harbor config: $field"
            echo
            echo "This field is an array, use the following actions to manage it:"
            echo
            echo "  ls            - List all values"
            echo "  clear         - Remove all values"
            echo "  rm <value>    - Remove a value"
            echo "  rm <index>    - Remove a value by index"
            echo "  add <value>   - Add a value"
            echo
            return 0
            ;;
    esac

    # Parse optional hook commands
    while [[ "$1" == --* ]]; do
        case "$1" in
            --on-get)
                get_command="$2"
                shift 2
                ;;
            --on-set)
                set_command="$2"
                shift 2
                ;;
            --on-add)
                add_command="$2"
                shift 2
                ;;
            --on-remove)
                remove_command="$2"
                shift 2
                ;;
        esac
    done

    local action=$1
    local value=$2

    # Helper function to get the current array
    get_array() {
        local array_string=$(env_manager get "$field")
        echo "$array_string"
    }

    # Helper function to set the array
    set_array() {
        local new_array=$1
        env_manager set "$field" "$new_array"
        if [ -n "$set_command" ]; then
            eval "$set_command"
        fi
    }

    case "$action" in
        ls|list|"")
            # Show all values
            local array=$(get_array)
            if [ -z "$array" ]; then
                echo "Config $field is empty"
            else
                echo "$array" | tr "$delimiter" "\n"
            fi
            if [ -n "$get_command" ]; then
                eval "$get_command"
            fi
            ;;
        clear)
            # Clear all values
            set_array ""
            echo "All values removed from $field"
            if [ -n "$remove_command" ]; then
                eval "$remove_command"
            fi
            ;;
        rm)
            if [ -z "$value" ]; then
                # Remove all values
                set_array ""
                echo "All values removed from $field"
            else
                # Remove one value
                local array=$(get_array)
                if [ "$value" -eq "$value" ] 2>/dev/null; then
                    # If value is a number, treat it as an index
                    local new_array=$(echo "$array" | awk -F"$delimiter" -v idx="$value" '{
                        OFS=FS;
                        for(i=1;i<=NF;i++) {
                            if(i-1 != idx) {
                                a[++n] = $i
                            }
                        }
                        for(i=1;i<=n;i++) {
                            printf("%s%s", a[i], (i==n)?"":OFS)
                        }
                    }')
                else
                    # Otherwise, treat it as a value to be removed
                    local new_array=$(echo "$array" | awk -F"$delimiter" -v val="$value" '{
                        OFS=FS;
                        for(i=1;i<=NF;i++) {
                            if($i != val) {
                                a[++n] = $i
                            }
                        }
                        for(i=1;i<=n;i++) {
                            printf("%s%s", a[i], (i==n)?"":OFS)
                        }
                    }')
                fi
                set_array "$new_array"
                echo "Value removed from $field"
            fi
            if [ -n "$remove_command" ]; then
                eval "$remove_command"
            fi
            ;;
        add)
            if [ -z "$value" ]; then
                echo "Usage: env_manager_arr $field add <value>"
                return 1
            fi
            local array=$(get_array)
            if [ -z "$array" ]; then
                new_array="$value"
            else
                new_array="${array}${delimiter}${value}"
            fi
            set_array "$new_array"
            echo "Value added to $field"
            if [ -n "$add_command" ]; then
                eval "$add_command"
            fi
            ;;
        -h|--help|help)
            echo "Usage: $field [--on-get <command>] [--on-set <command>] [--on-add <command>] [--on-remove <command>] {ls|rm|add} [value]"
            ;;
        *)
            return $scramble_exit_code
            ;;
    esac
}

override_yaml_value() {
    local file="$1"
    local key="$2"
    local new_value="$3"
    local temp_file="$(mktemp)"

    if [ -z "$file" ] || [ -z "$key" ] || [ -z "$new_value" ]; then
        echo "Usage: override_yaml_value <file_path> <key> <new_value>"
        return 1
    fi

    awk -v key="$key" -v value="$new_value" '
    $0 ~ key {
        sub(/:[[:space:]]*.*/, ": " value)
    }
    {print}
    ' "$file" > "$temp_file" && mv "$temp_file" "$file"

    if [ $? -eq 0 ]; then
        echo "Successfully updated '$key' in $file"
    else
        echo "Failed to update '$key' in $file"
        return 1
    fi
}

# shellcheck disable=SC2034
__anchor_utils=true

run_harbor_find() {
    find $(eval echo "$(env_manager get hf.cache)") \
        $(eval echo "$(env_manager get llamacpp.cache)") \
        $(eval echo "$(env_manager get ollama.cache)") \
        $(eval echo "$(env_manager get vllm.cache)") \
        -xtype f -wholename "*$**";
}

run_hf_docker_cli() {
    $(compose_with_options "hf") run --rm hf "$@"
}

check_hf_cache() {
    local maybe_cache_entry

    maybe_cache_entry=$(run_hf_docker_cli scan-cache | grep $1)

    if [ -z "$maybe_cache_entry" ]; then
        echo "$1 is missing in Hugging Face cache." >&2
        return 1
    else
        echo "$1 found in the cache." >&2
        return 0
    fi
}

parse_hf_url() {
    local url=$1
    local base_url="https://huggingface.co/"
    local ref="/blob/main/"

    # Extract repo name
    repo_name=${url#$base_url}
    repo_name=${repo_name%%$ref*}

    # Extract file specifier
    file_specifier=${url#*$ref}

    # Return values separated by a delimiter (we'll use '|')
    echo "$repo_name$delimiter$file_specifier"
}

hf_url_2_llama_spec() {
    local decomposed=$(parse_hf_url $1)
    local repo_name=$(echo "$decomposed" | cut -d"$delimiter" -f1)
    local file_specifier=$(echo "$decomposed" | cut -d"$delimiter" -f2)

    echo "--hf-repo $repo_name --hf-file $file_specifier"
}

hf_spec_2_folder_spec() {
    # Replace all "/" with "_"
    echo "${1//\//_}"
}


docker_fsacl() {
    local folder=$1
    sudo setfacl --recursive -m user:1000:rwx $folder && sudo setfacl --recursive -m user:1002:rwx $folder && sudo setfacl --recursive -m user:1001:rwx $folder
}

fix_fs_acl() {
    docker_fsacl ./ollama
    docker_fsacl ./langfuse
    docker_fsacl ./open-webui
    docker_fsacl ./tts
    docker_fsacl ./librechat
    docker_fsacl ./searxng
    docker_fsacl ./tabbyapi
    docker_fsacl ./litellm
    docker_fsacl ./dify

    docker_fsacl $(eval echo "$(env_manager get hf.cache)")
    docker_fsacl $(eval echo "$(env_manager get vllm.cache)")
    docker_fsacl $(eval echo "$(env_manager get llamacpp.cache)")
    docker_fsacl $(eval echo "$(env_manager get ollama.cache)")
    docker_fsacl $(eval echo "$(env_manager get parllama.cache)")
    docker_fsacl $(eval echo "$(env_manager get opint.config.path)")
    docker_fsacl $(eval echo "$(env_manager get fabric.config.path)")
}

open_home_code() {
    # If VS Code executable is available
    if command -v code &> /dev/null; then
        code "$harbor_home"
    else
        # shellcheck disable=SC2016
        echo '"code" is not installed or not available in $PATH.'
    fi
}

unsafe_update() {
    git pull
}

resolve_harbor_version() {
  git ls-remote --tags "$HARBOR_REPO_URL" | grep -o "v.*" | sort -r | head -n 1
}

update_harbor() {
    local is_latest=false

    case "$1" in
        --latest|-l)
            is_latest=true
            ;;
    esac

    if $is_latest; then
        echo "Updating to the bleeding edge version..."
        unsafe_update
    else
        harbor_version=$(resolve_harbor_version)
        echo "Updating to version $harbor_version..."
        git checkout tags/$harbor_version
    fi
}

get_active_services() {
    docker compose ps --format "{{.Service}}" | tr '\n' ' '
}

is_service_running() {
    if docker compose ps --services --filter "status=running" | grep -q "^$1$"; then
        return 0
    else
        return 1
    fi
}

get_services() {
    local is_active=false
    local filtered_args=()

    for arg in "$@"; do
        case "$arg" in
            --active|-a)
                is_active=true
                ;;
            *)
                filtered_args+=("$arg") # Add to filtered arguments
                ;;
        esac
    done

    if $is_active; then
        local active_services=$(docker compose ps --format "{{.Service}}")

        if [ -z "$active_services" ]; then
            echo "Harbor has no active services."
        else
            echo "Harbor active services:"
            echo "$active_services"
        fi
    else
        echo "Harbor services:"
        $(compose_with_options "*") config --services
    fi
}

get_ip() {
    # Try ip command first
    ip_cmd=$(which ip 2>/dev/null)
    if [ -n "$ip_cmd" ]; then
        ip route get 1 | awk '{print $7; exit}'
        return
    fi

    # Fallback to ifconfig
    ifconfig_cmd=$(which ifconfig 2>/dev/null)
    if [ -n "$ifconfig_cmd" ]; then
        ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1
        return
    fi

    # Last resort: hostname
    hostname -I | awk '{print $1}'
}

extract_tunnel_url() {
    grep -oP '(?<=\|  )https://[^[:space:]]+\.trycloudflare\.com(?=\s+\|)' | head -n1
}

establish_tunnel() {
    case $1 in
        down|stop|d|s)
            echo "Stopping all tunnels"
            docker stop $(docker ps -q --filter "name=cfd.tunnel") || true
            exit 0
            ;;
    esac

    local intra_url=$(get_url -i "$@")
    local container_name=$(get_container_name "cfd.tunnel.$(date +%s)")
    local tunnel_url=""

    echo "Starting new tunnel"
    echo "Container name: $container_name"
    echo "Intra URL: $intra_url"
    $(compose_with_options "cfd") run -d --name "$container_name" cfd --url "$intra_url" || { echo "Failed to start container"; exit 1; }

    local timeout=60
    local elapsed=0
    while [ -z "$tunnel_url" ] && [ $elapsed -lt $timeout ]; do
        sleep 1
        echo "Waiting for tunnel URL..."
        tunnel_url=$(docker logs -n 200 $container_name 2>&1 | extract_tunnel_url) || true
        elapsed=$((elapsed + 1))
    done

    if [ -z "$tunnel_url" ]; then
        echo "Failed to obtain tunnel URL within $timeout seconds"
        docker stop "$container_name" || true
        exit 1
    fi

    echo "Tunnel URL: $tunnel_url"
    print_qr "$tunnel_url" || { echo "Failed to print QR code"; exit 1; }
}
# shellcheck disable=SC2034
__anchor_service_clis=true

run_gum() {
    local gum_image=ghcr.io/charmbracelet/gum
    docker run --rm -it -e "TERM=xterm-256color" $gum_image "$@"
}

run_dive() {
    local dive_image=wagoodman/dive
    docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock $dive_image "$@"
}

run_llamacpp_command() {
    update_model_spec() {
        local spec=""
        local current_model=$(env_manager get llamacpp.model)
        local current_gguf=$(env_manager get llamacpp.gguf)

        if [ -n "$current_model" ]; then
            spec=$(hf_url_2_llama_spec $current_model)
        else
            spec="-m $current_gguf"
        fi

        env_manager set llamacpp.model.specifier "$spec"
    }

    case "$1" in
        model)
            shift
            env_manager_alias llamacpp.model --on-set update_model_spec "$@"
            ;;
        gguf)
            shift
            env_manager_alias llamacpp.gguf "$@"
            ;;
        args)
            shift
            env_manager_alias llamacpp.extra.args "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not llama.cpp CLI, but a Harbor CLI to manage llama.cpp service."
            echo "Access llama.cpp own CLI by running 'harbor exec llamacpp' when it's running."
            echo
            echo "Usage: harbor llamacpp <command>"
            echo
            echo "Commands:"
            echo "  harbor llamacpp model [Hugging Face URL] - Get or set the llamacpp model to run"
            echo "  harbor llamacpp gguf [gguf path]         - Get or set the path to GGUF to run"
            echo "  harbor llamacpp args [args]              - Get or set extra args to pass to the llama.cpp CLI"
            ;;
        *)
            return $scramble_exit_code
    esac
}

run_tgi_command() {
    update_model_spec() {
        local spec=""
        local current_model=$(env_manager get tgi.model)
        local current_quant=$(env_manager get tgi.quant)
        local current_revision=$(env_manager get tgi.revision)

        if [ -n "$current_model" ]; then
            spec="--model-id $current_model"
        fi

        if [ -n "$current_quant" ]; then
            spec="$spec --quantize $current_quant"
        fi

        if [ -n "$current_revision" ]; then
            spec="$spec --revision $current_revision"
        fi

        env_manager set tgi.model.specifier "$spec"
    }

    case "$1" in
        model)
            shift
            env_manager_alias tgi.model --on-set update_model_spec "$@"
            ;;
        args)
            shift
            env_manager_alias tgi.extra.args "$@"
            ;;
        quant)
            shift
            env_manager_alias tgi.quant --on-set update_model_spec "$@"
            ;;
        revision)
            shift
            env_manager_alias tgi.revision --on-set update_model_spec "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not TGI CLI, but a Harbor CLI to manage TGI service."
            echo "Access TGI own CLI by running 'harbor exec tgi' when it's running."
            echo
            echo "Usage: harbor tgi <command>"
            echo
            echo "Commands:"
            echo "  harbor tgi model [user/repo]   - Get or set the TGI model repository to run"
            echo "  harbor tgi quant"
            echo "    [awq|eetq|exl2|gptq|marlin|bitsandbytes|bitsandbytes-nf4|bitsandbytes-fp4|fp8]"
            echo "    Get or set the TGI quantization mode. Must match the contents of the model repository."
            echo "  harbor tgi revision [revision] - Get or set the TGI model revision to run"
            echo "  harbor tgi args [args]         - Get or set extra args to pass to the TGI CLI"
            ;;
        *)
            return $scramble_exit_code
    esac
}

run_litellm_command() {
    case "$1" in
        username)
            shift
            env_manager_alias litellm.ui.username "$@"
            ;;
        password)
            shift
            env_manager_alias litellm.ui.password "$@"
            ;;
        ui)
            shift
            if service_url=$(get_url litellm 2>&1); then
                sys_open "$service_url/ui"
            else
                echo "Error: Failed to get service URL for litellm: $service_url"
                exit 1
            fi
            ;;
        -h|--help|help)
            echo "Please note that this is not LiteLLM CLI, but a Harbor CLI to manage LiteLLM service."
            echo
            echo "Usage: harbor litellm <command>"
            echo
            echo "Commands:"
            echo "  harbor litellm username [username] - Get or set the LITeLLM UI username"
            echo "  harbor litellm password [username] - Get or set the LITeLLM UI password"
            echo "  harbor litellm ui                  - Open LiteLLM UI screen"
            ;;
        *)
            return $scramble_exit_code
    esac
}

run_hf_command() {
    case "$1" in
        parse-url)
            shift
            parse_hf_url "$@"
            return
            ;;
        token)
            shift
            env_manager_alias hf.token "$@"
            return
            ;;
        cache)
            shift
            env_manager_alias hf.cache "$@"
            return
            ;;
        dl)
            shift
            $(compose_with_options "hfdownloader") run --rm hfdownloader "$@"
            return
            ;;
        path)
            shift
            local found_path
            local spec="$1"

            if check_hf_cache "$1"; then
                found_path=$(run_hf_docker_cli download "$1")
                echo "$found_path"
            fi

            return
            ;;
        find)
            shift
            run_hf_open "$@"
            return
            ;;
        # Matching HF signature, but would love just "help"
        -h|--help)
            echo "Please note that this is a combination of Hugging Face"
            echo "CLI with additional Harbor-specific commands."
            echo
            echo "Harbor extensions:"
            echo "Usage: harbor hf <command>"
            echo
            echo "Commands:"
            echo "  harbor hf token [token]    - Get or set the Hugging Face API token"
            echo "  harbor hf cache            - Get or set the location of Hugging Face cache"
            echo "  harbor hf dl [args]        - Download a model from Hugging Face"
            echo "  harbor hf path [user/repo] - Resolve the path to a model dir in HF cache"
            echo "  harbor hf find [query]     - Search for a model on Hugging Face"
            echo
            echo "Original CLI help:"
            ;;
    esac

    run_hf_docker_cli "$@"
}

run_vllm_command() {
    update_model_spec() {
        local spec=""
        local current_model=$(env_manager get vllm.model)

        if [ -n "$current_model" ]; then
            spec="--model $current_model"
        fi

        env_manager set vllm.model.specifier "$spec"

        # Litellm model specifier for vLLM
        override_yaml_value ./litellm/litellm.vllm.yaml "model:" "openai/$current_model"
    }

    case "$1" in
        model)
            shift
            env_manager_alias vllm.model --on-set update_model_spec "$@"
            ;;
        args)
            shift
            env_manager_alias vllm.extra.args "$@"
            ;;
        attention)
            shift
            env_manager_alias vllm.attention_backend "$@"
            ;;
        version)
            shift
            env_manager_alias vllm.version "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not VLLM CLI, but a Harbor CLI to manage VLLM service."
            echo "Access VLLM own CLI by running 'harbor exec vllm' when it's running."
            echo
            echo "Usage: harbor vllm <command>"
            echo
            echo "Commands:"
            echo "  harbor vllm model [user/repo]   - Get or set the VLLM model repository to run"
            echo "  harbor vllm args [args]         - Get or set extra args to pass to the VLLM CLI"
            echo "  harbor vllm attention [backend] - Get or set the attention backend to use"
            echo "  harbor vllm version [version]   - Get or set VLLM version (docker tag)"
            ;;
        *)
            return $scramble_exit_code
    esac
}

run_aphrodite_command() {
    case "$1" in
        model)
            shift
            env_manager_alias aphrodite.model "$@"
            ;;
        args)
            shift
            env_manager_alias aphrodite.extra.args "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not Aphrodite CLI, but a Harbor CLI to manage Aphrodite service."
            echo "Access Aphrodite own CLI by running 'harbor exec aphrodite' when it's running."
            echo
            echo "Usage: harbor aphrodite <command>"
            echo
            echo "Commands:"
            echo "  harbor aphrodite model <user/repo>   - Get/set the Aphrodite model to run"
            echo "  harbor aphrodite args <args>         - Get/set extra args to pass to the Aphrodite CLI"
            ;;
        *)
            return $scramble_exit_code
    esac
}

run_open_ai_command() {
    update_main_key() {
        local key=$(env_manager get openai.keys | cut -d";" -f1)
        env_manager set openai.key "$key"
    }

    update_main_url() {
        local url=$(env_manager get openai.urls | cut -d";" -f1)
        env_manager set openai.url "$url"
    }

    case "$1" in
        keys)
            shift
            env_manager_arr openai.keys --on-set update_main_key "$@"
            ;;
        urls)
            shift
            env_manager_arr openai.urls --on-set update_main_url "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not an OpenAI CLI, but a Harbor CLI to manage OpenAI configuration."
            echo
            echo "Usage: harbor openai <command>"
            echo
            echo "Commands:"
            echo "  harbor openai keys [ls|rm|add]   - Get/set the API Keys for the OpenAI-compatible APIs."
            echo "  harbor openai urls [ls|rm|add]   - Get/set the API URLs for the OpenAI-compatible APIs."
            ;;
        *)
            return $scramble_exit_code
    esac
}

run_webui_command() {
    case "$1" in
        secret)
            shift
            env_manager_alias webui.secret "$@"
            ;;
        name)
            shift
            env_manager_alias webui.name "$@"
            ;;
        log)
            shift
            env_manager_alias webui.log.level "$@"
            ;;
        version)
            shift
            env_manager_alias webui.version "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not WebUI CLI, but a Harbor CLI to manage WebUI service."
            echo
            echo "Usage: harbor webui <command>"
            echo
            echo "Commands:"
            echo "  harbor webui secret [secret]   - Get/set WebUI JWT Secret"
            echo "  harbor webui name [name]       - Get/set the name WebUI will present"
            echo "  harbor webui log [level]       - Get/set WebUI log level"
            echo "  harbor webui version [version] - Get/set WebUI version docker tag"
            return 1
            ;;
        *)
            return $scramble_exit_code
            ;;
    esac
}

run_tabbyapi_command() {
    update_model_spec() {
        local spec=""
        local current_model=$(env_manager get tabbyapi.model)

        if [ -n "$current_model" ]; then
            spec=$(hf_spec_2_folder_spec $current_model)
        fi

        env_manager set tabbyapi.model.specifier "$spec"
    }

    case "$1" in
        model)
            shift
            env_manager_alias tabbyapi.model --on-set update_model_spec "$@"
            ;;
        args)
            shift
            env_manager_alias tabbyapi.extra.args "$@"
            ;;
        apidoc)
            shift
            if service_url=$(get_url tabbyapi 2>&1); then
                sys_open "$service_url/docs"
            else
                echo "Error: Failed to get service URL for tabbyapi: $service_url"
                exit 1
            fi
            ;;
        -h|--help|help)
            echo "Please note that this is not TabbyAPI CLI, but a Harbor CLI to manage TabbyAPI service."
            echo "Access TabbyAPI own CLI by running 'harbor exec tabbyapi' when it's running."
            echo
            echo "Usage: harbor tabbyapi <command>"
            echo
            echo "Commands:"
            echo "  harbor tabbyapi model [user/repo]   - Get or set the TabbyAPI model repository to run"
            echo "  harbor tabbyapi args [args]         - Get or set extra args to pass to the TabbyAPI CLI"
            echo "  harbor tabbyapi apidoc              - Open TabbyAPI built-in API documentation"
            ;;
        *)
            return $scramble_exit_code
    esac
}

run_parllama_command() {
    $(compose_with_options "parllama") run -it --entrypoint bash parllama -c parllama
}

run_plandex_command() {
    case "$1" in
        health)
            shift
            execute_and_process "get_url plandexserver" "curl {{output}}/health" "No plandexserver URL:"
            ;;
        pwd)
            shift
            echo $original_dir
            ;;
        *)
            $(compose_with_options "plandex") run -v "$original_dir:/app/context" --workdir "/app/context" -it --entrypoint "plandex" plandex "$@"
            ;;
    esac
}

run_mistralrs_command() {
    update_model_spec() {
        local spec=""
        local current_model=$(env_manager get mistralrs.model)
        local current_type=$(env_manager get mistralrs.model_type)
        local current_arch=$(env_manager get mistralrs.model_arch)
        local current_isq=$(env_manager get mistralrs.isq)

        if [ -n "$current_isq" ]; then
            spec="--isq $current_isq"
        fi

        if [ -n "$current_type" ]; then
            spec="$spec $current_type"
        fi

        if [ -n "$current_model" ]; then
            spec="$spec -m $current_model"
        fi

        if [ -n "$current_arch" ]; then
            spec="$spec -a $current_arch"
        fi

        env_manager set mistralrs.model.specifier "$spec"
    }

    case "$1" in
        health)
            shift
            execute_and_process "get_url mistralrs" "curl {{output}}/health" "No mistralrs URL:"
            ;;
        docs)
            shift
            execute_and_process "get_url mistralrs" "sys_open {{output}}/docs" "No mistralrs URL:"
            ;;
        args)
            shift
            env_manager_alias mistralrs.extra.args "$@"
            ;;
        model)
            shift
            env_manager_alias mistralrs.model --on-set update_model_spec "$@"
            ;;
        type)
            shift
            env_manager_alias mistralrs.model_type --on-set update_model_spec "$@"
            ;;
        arch)
            shift
            env_manager_alias mistralrs.model_arch --on-set update_model_spec "$@"
            ;;
        isq)
            shift
            env_manager_alias mistralrs.isq --on-set update_model_spec "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not mistral.rs CLI, but a Harbor CLI to manage mistral.rs service."
            echo "Access mistral.rs own CLI by running 'harbor exec mistralrs' when it's running."
            echo
            echo "Usage: harbor mistralrs <command>"
            echo
            echo "Commands:"
            echo "  harbor mistralrs health            - Check the health of the mistral.rs service"
            echo "  harbor mistralrs docs              - Open mistral.rs built-in API documentation"
            echo "  harbor mistralrs args [args]       - Get or set extra args to pass to the mistral.rs CLI"
            echo "  harbor mistralrs model [user/repo] - Get or set the mistral.rs model repository to run"
            echo "  harbor mistralrs type [type]       - Get or set the mistral.rs model type"
            echo "  harbor mistralrs arch [arch]       - Get or set the mistral.rs model architecture"
            echo "  harbor mistralrs isq [isq]         - Get or set the mistral.rs model ISQ"
            ;;
        *)
            $(compose_with_options "mistralrs") run mistralrs "$@"
            ;;
    esac
}

run_opint_command() {
    update_cmd() {
        local cmd=""
        local current_model=$(env_manager get opint.model)
        local current_args=$(env_manager get opint.extra.args)

        if [ -n "$current_model" ]; then
            cmd="--model $current_model"
        fi

        if [ -n "$current_args" ]; then
            cmd="$cmd $current_args"
        fi

        env_manager set opint.cmd "$cmd"
    }

    clear_cmd_srcs() {
        env_manager set opint.model ""
        env_manager set opint.args ""
    }

    case "$1" in
        backend)
            shift
            env_manager_alias opint.backend "$@"
            ;;
        profiles|--profiles|-p)
            shift
            execute_and_process "env_manager get opint.config.path" "sys_open {{output}}/profiles" "No opint.config.path set"
            ;;
        models|--local_models)
            shift
            execute_and_process "env_manager get opint.config.path" "sys_open {{output}}/models" "No opint.config.path set"
            ;;
        pwd)
            shift
            echo "$original_dir"
            ;;
        model)
            shift
            env_manager_alias opint.model --on-set update_cmd "$@"
            ;;
        args)
            shift
            env_manager_alias opint.extra.args --on-set update_cmd "$@"
            ;;
        cmd)
            shift
            env_manager_alias opint.cmd "$@"
            ;;
        -os|--os)
            shift
            echo "Harbor does not support Open Interpreter OS mode".
            ;;
        *)
            # Allow permanent override of the target backend
            local services=$(env_manager get opint.backend)

            if [ -z "$services" ]; then
                services=$(get_active_services)
            fi

            # Mount the current directory and set it as the working directory
            $(compose_with_options "$services" "opint") run -v "$original_dir:$original_dir" --workdir "$original_dir" opint $@
            ;;
    esac
}

run_cmdh_command() {
    case "$1" in
        model)
            shift
            env_manager_alias cmdh.model "$@"
            ;;
        host)
            shift
            env_manager_alias cmdh.llm.host "$@"
            ;;
        key)
            shift
            env_manager_alias cmdh.llm.key "$@"
            ;;
        url)
            shift
            env_manager_alias cmdh.llm.url "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not cmdh CLI, but a Harbor CLI to manage cmdh service."
            echo "Access cmdh own CLI by running 'harbor exec cmdh' when it's running."
            echo
            echo "Usage: harbor cmdh <command>"
            echo
            echo "Commands:"
            echo "  harbor cmdh model [user/repo]    - Get or set the cmdh model repository to run"
            echo "  harbor cmdh host [ollama|OpenAI] - Get or set the cmdh LLM host"
            echo "  harbor cmdh key [key]            - Get or set the cmdh OpenAI LLM key"
            echo "  harbor cmdh url [url]            - Get or set the cmdh OpenAI LLM URL"
            ;;
        *)
            local services=$(get_active_services)
            # Mount the current directory and set it as the working directory
            $(compose_with_options $services "cmdh") run \
                -v "$original_dir:$original_dir" \
                --workdir "$original_dir" \
                cmdh "$*"
            ;;
    esac
}

run_harbor_cmdh_command() {
    # Check if ollama is running
    if ! is_service_running "ollama"; then
        echo "Please start ollama service to use 'harbor how'"
        exit 1
    fi

    local services=$(get_active_services)

    # Mount the current directory and set it as the working directory
    $(compose_with_options $services "cmdh" "harbor") run \
        -v "$harbor_home/cmdh/harbor.prompt:/app/cmdh/system.prompt" \
        -v "$original_dir:$original_dir" \
        --workdir "$original_dir" \
        cmdh "$*"
}

run_fabric_command() {
    case "$1" in
        model)
            shift
            env_manager_alias fabric.model "$@"
            return 0
            ;;
        patterns|--patterns)
            shift
            execute_and_process "env_manager get fabric.config.path" "sys_open {{output}}/patterns" "No fabric.config.path set"
            return 0
            ;;
        -h|--help|help)
            echo "Please note that this is not Fabric CLI, but a Harbor CLI to manage Fabric service."
            echo
            echo "Usage: harbor fabric <command>"
            echo
            echo "Commands:"
            echo "  harbor fabric -h|--help|help    - Show this help message"
            echo "  harbor fabric model [user/repo] - Get or set the Fabric model repository to run"
            echo "  harbor fabric patterns          - Open the Fabric patterns directory"
            echo
            echo "Fabric CLI Help:"
            ;;
    esac

    local services=$(get_active_services)

    # To allow using preferred pipe pattern for fabric
    $(compose_with_options $services "fabric") run \
        -T \
        -v "$original_dir:$original_dir" \
        --workdir "$original_dir" \
        fabric "$@"
}

run_parler_command() {
    case "$1" in
        model)
            shift
            env_manager_alias parler.model "$@"
            ;;
        voice)
            shift
            env_manager_alias parler.voice "$@"
            ;;
        -h|--help|help)
            echo "Please note that this is not Parler CLI, but a Harbor CLI to manage Parler service."
            echo
            echo "Usage: harbor parler <command>"
            echo
            echo "Commands:"
            echo "  harbor parler -h|--help|help - Show this help message"
            ;;
        *)
            return $scramble_exit_code
            ;;
    esac
}


# ========================================================================
# == Main script
# ========================================================================

version="0.1.3"
delimiter="|"
scramble_exit_code=42

harbor_home=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
original_dir=$PWD
cd "$harbor_home" || exit

ensure_env_file

default_options=($(env_manager get services.default | tr ';' ' '))
default_tunnels=($(env_manager get services.tunnels | tr ';' ' '))
default_open=$(env_manager get ui.main)
default_autoopen=$(env_manager get ui.autoopen)
default_container_prefix=$(env_manager get container.prefix)

main_entrypoint() {
    case "$1" in
        up|u)
            shift
            harbor_up "$@"
            ;;
        down|d)
            shift
            $(compose_with_options "*") down --remove-orphans "$@"
            ;;
        restart|r)
            shift
            $(compose_with_options "*") down --remove-orphans "$@"
            $(compose_with_options "$@") up -d
            ;;
        ps)
            shift
            $(compose_with_options "*") ps
            ;;
        build)
            shift
            service=$1
            shift
            $(compose_with_options "*") build "$service" "$@"
            ;;
        shell)
            shift
            service=$1
            shift

            if [ -z "$service" ]; then
                echo "Usage: harbor shell <service>"
                exit 1
            fi

            $(compose_with_options "*") run -it --entrypoint bash "$service"
            ;;
        logs|l)
            shift
            # Only pass "*" to the command if no options are provided
            $(compose_with_options "*") logs -n 20 -f "$@"
            ;;
        pull)
            shift
            $(compose_with_options "$@") pull
            ;;
        exec)
            shift
            run_in_service "$@"
            ;;
        run)
            shift
            service=$1
            shift

            local services=$(get_active_services)
            $(compose_with_options $services "$service") run --rm "$service" "$@"
            ;;
        cmd)
            shift
            resolve_compose_command "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        hf)
            shift
            run_hf_command "$@"
            ;;
        defaults)
            shift
            env_manager_arr services.default "$@"
            ;;
        link|ln)
            shift
            link_cli "$@"
            ;;
        unlink)
            shift
            unlink_cli "$@"
            ;;
        open|o)
            shift
            open_service "$@"
            ;;
        url)
            shift
            get_url $@
            ;;
        qr)
            shift
            print_service_qr "$@"
            ;;
        list|ls)
            shift
            get_services "$@"
            ;;
        version|--version|-v)
            shift
            show_version
            ;;
        smi)
            shift
            smi
            ;;
        top)
            shift
            nvidia_top
            ;;
        dive)
            shift
            run_dive "$@"
            ;;
        eject)
            shift
            eject "$@"
            ;;
        ollama)
            shift
            run_in_service ollama ollama "$@"
            ;;
        llamacpp)
            shift
            run_llamacpp_command "$@"
            ;;
        tgi)
            shift
            run_tgi_command "$@"
            ;;
        litellm)
            shift
            run_litellm_command "$@"
            ;;
        vllm)
            shift
            run_vllm_command "$@"
            ;;
        aphrodite)
            shift
            run_aphrodite_command "$@"
            ;;
        openai)
            shift
            run_open_ai_command "$@"
            ;;
        webui)
            shift
            run_webui_command "$@"
            ;;
        tabbyapi)
            shift
            run_tabbyapi_command "$@"
            ;;
        parllama)
            shift
            run_parllama_command "$@"
            ;;
        plandex|pdx)
            shift
            run_plandex_command "$@"
            ;;
        mistralrs)
            shift
            run_mistralrs_command "$@"
            ;;
        interpreter|opint)
            shift
            run_opint_command "$@"
            ;;
        cfd|cloudflared)
            shift
            $(compose_with_options "cfd") run cfd "$@"
            ;;
        cmdh)
            shift
            run_cmdh_command "$@"
            ;;
        fabric)
            shift
            run_fabric_command "$@"
            ;;
        parler)
            shift
            run_parler_command "$@"
            ;;
        tunnel|t)
            shift
            establish_tunnel "$@"
            ;;
        tunnels)
            shift
            env_manager_arr services.tunnels "$@"
            ;;
        config)
            shift
            env_manager "$@"
            ;;
        gum)
            shift
            run_gum "$@"
            ;;
        fixfs)
            shift
            fix_fs_acl
            ;;
        info)
            shift
            sys_info
            ;;
        update)
            shift
            update_harbor "$@"
            ;;
        how)
            shift
            run_harbor_cmdh_command "$@"
            ;;
        find)
            shift
            run_harbor_find "$@"
            ;;
        home)
            shift
            echo "$harbor_home"
            ;;
        vscode)
            shift
            open_home_code
            ;;
        *)
            return $scramble_exit_code
            ;;
    esac
}


# Call the main logic with argument swapping
if ! swap_and_retry main_entrypoint "$@"; then
    show_help
    exit 1
fi