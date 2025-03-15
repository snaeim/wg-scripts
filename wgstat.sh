#!/bin/bash

# Variables
SCRIPT_NAME=$(basename "$0")
DB_PATH="/var/lib/$SCRIPT_NAME"

# Error codes
ERR_UNKNOWN_COMMAND=10
ERR_INTERFACE_NAME_REQUIRED=11
ERR_INTERFACE_NOT_EXIST=12
ERR_JQ_PROCESSING=13
ERR_FILE_NOT_FOUND=14
ERR_INVALID_TIMESTAMP=15
ERR_INVALID_BYTES=16
ERR_REMOVE_FAILED=17
ERR_ROOT_PRIVILEGE_REQUIRED=18
ERR_FILE_WRITE_FAILED=19
ERR_NO_INTERFACES_FOUND=20

# Function to calculate time difference
time_diff() {
  local timestamp=$1
  [[ -z "$timestamp" ]] || [[ ! "$timestamp" =~ ^[0-9]+$ ]] && return $ERR_INVALID_TIMESTAMP
    
  local diff=$(($(date +%s) - timestamp))
  ((diff == 0)) && echo "Just now" && return 0

  local out="" count=0
  local -A units=([month]=2592000 [day]=86400 [hour]=3600 [minute]=60 [second]=1)
  for unit in month day hour minute second; do
    ((count == 3)) && break
    local val=$((diff / units[$unit]))
    diff=$((diff % units[$unit]))
    ((val == 0)) && continue
    [[ -n $out ]] && out+=", "
    out+="$val $unit"
    ((val > 1)) && out+="s"
    ((count++))
  done

  echo "$out ago"
  return 0
}

format_iec() {
  local bytes=$1
  [[ -z "$bytes" || "$bytes" =~ [^0-9] ]] && return $ERR_INVALID_BYTES
  local units=("B" "KiB" "MiB" "GiB" "TiB")
  local thresholds=(1 1024 1048576 1073741824 1099511627776)
  
  # Special case for bytes (no decimal places needed)
  if ((bytes < 1024)); then
    echo "$bytes ${units[0]}"
    return 0
  fi
  
  # For KiB and above, use decimal places
  for i in {1..4}; do
    if ((bytes < thresholds[i+1])) || ((i == 4)); then
      local size=$(awk "BEGIN {printf \"%.2f\", $bytes / ${thresholds[$i]}}")
      echo "${size} ${units[$i]}"
      return 0
    fi
  done
}

# Function to update WireGuard interface
update_interface() {
  local interface_name="$1"
  [[ -z "$interface_name" ]] && return $ERR_INTERFACE_NAME_REQUIRED
  
  # Get WireGuard information in one call
  local wg_dump
  wg_dump=$(wg show "$interface_name" dump 2>&1) || return $ERR_INTERFACE_NOT_EXIST
 
  # Load or create JSON data
  local json_data
  local file_path="$DB_PATH/$interface_name.json"
  if [[ -f "$file_path" && -s "$file_path" ]]; then
    json_data=$(<"$file_path")
  else
    json_data='{"interface": {}, "peers": {}}'
  fi
  
  # Get current timestamp
  local ts_now=$(date +%s)
  
  # Process interface info
  local interface_public_key interface_listen_port
  read -r _ interface_public_key interface_listen_port _ <<< "$(head -n 1 <<< "$wg_dump")"
  
  # Update interface data
  json_data=$(jq --arg name "$interface_name" \
                 --arg pub_key "$interface_public_key" \
                 --arg listen_port "$interface_listen_port" \
                 --arg ts_now "$ts_now" \
                 '.interface.name=$name | .interface.public_key=$pub_key | .interface.listen_port=$listen_port |
                  (.interface.create_at //= $ts_now) | .interface.update_at=$ts_now' <<< "$json_data") || return $ERR_JQ_PROCESSING
  
  # Get peer data (line count > 1 means peers exist)
  local peer_data
  peer_data=$(tail -n +2 <<< "$wg_dump")
  [[ -z "$peer_data" ]] && { echo "$json_data" > "$file_path" || return $ERR_FILE_WRITE_FAILED; return 0; }
  
  # Process each peer
  local peer_public_key peer_endpoint peer_allowed_ips peer_latest_handshake peer_transfer_rx peer_transfer_tx peer_persistent_keepalive
  local total_rx total_tx prev_transfer_rx prev_transfer_tx
  while IFS=$'\t' read -r peer_public_key _ peer_endpoint peer_allowed_ips peer_latest_handshake peer_transfer_rx peer_transfer_tx peer_persistent_keepalive; do
    # Skip peers with no latest handshake
    #[[ -z "$peer_latest_handshake" || "$peer_latest_handshake" == "0" ]] && continue
    
    # Set default values for a new peer
    json_data=$(jq --arg key "$peer_public_key" \
                   '.peers[$key] //= {
                     "allowed_ips": "",
                     "transfer_rx": 0,
                     "transfer_tx": 0,
                     "total_rx": 0,
                     "total_tx": 0,
                     "persistent_keepalive": "off",
                     "endpoint": "(none)",
                     "latest_handshake": 0
                   }' <<< "$json_data") || return $ERR_JQ_PROCESSING
    
    # Get existing values
    read -r total_rx total_tx prev_transfer_rx prev_transfer_tx < <(jq -r "
      .peers[\"$peer_public_key\"] | \"\(.total_rx) \(.total_tx) \(.transfer_rx) \(.transfer_tx)\"
    " <<< "$json_data")
    
    # Update totals
    if [[ "$peer_transfer_rx" -lt "$prev_transfer_rx" || "$peer_transfer_tx" -lt "$prev_transfer_tx" ]]; then
      # Counter reset, add new values
      total_rx=$((total_rx + peer_transfer_rx))
      total_tx=$((total_tx + peer_transfer_tx))
    else
      # Add difference
      total_rx=$((total_rx + peer_transfer_rx - prev_transfer_rx))
      total_tx=$((total_tx + peer_transfer_tx - prev_transfer_tx))
    fi
    
    # Update peer data - using correct structure with parentheses for conditionals
    json_data=$(jq --arg peer "$peer_public_key" \
                   --arg allowed_ips "$peer_allowed_ips" \
                   --argjson transfer_rx "$peer_transfer_rx" \
                   --argjson transfer_tx "$peer_transfer_tx" \
                   --argjson total_rx "$total_rx" \
                   --argjson total_tx "$total_tx" \
                   --arg persistent_keepalive "$peer_persistent_keepalive" \
                   --arg endpoint "$peer_endpoint" \
                   --argjson latest_handshake "$peer_latest_handshake" \
                   '(.peers[$peer].allowed_ips=$allowed_ips |
                     .peers[$peer].transfer_rx=$transfer_rx |
                     .peers[$peer].transfer_tx=$transfer_tx |
                     .peers[$peer].total_rx=$total_rx |
                     .peers[$peer].total_tx=$total_tx |
                     .peers[$peer].persistent_keepalive=$persistent_keepalive) |
                    (if $latest_handshake != 0 then .peers[$peer].latest_handshake = $latest_handshake else . end) |
                    (if $endpoint != "(none)" then .peers[$peer].endpoint = $endpoint else . end)' <<< "$json_data") || return $ERR_JQ_PROCESSING
  done <<< "$peer_data"
  
  # Write updated data
  echo "$json_data" > "$file_path" || return $ERR_FILE_WRITE_FAILED
  return 0
}

show_interface() {
  local interface_name="$1"
  [[ -z "$interface_name" ]] && return $ERR_INTERFACE_NAME_REQUIRED

  local file_path="$DB_PATH/$interface_name.json"
  [[ -f "$file_path" ]] || return $ERR_FILE_NOT_FOUND
  
  local json_data=$(<"$file_path")

  local name public_key listen_port create_at update_at peers
  read -r name public_key listen_port create_at update_at peers < <(jq -r '
    (.interface | "\(.name) \(.public_key) \(.listen_port) \(.create_at) \(.update_at) ") + 
    (.peers | to_entries | 
    [(. | map(select(.value.latest_handshake > 0))) | sort_by(.value.latest_handshake) | reverse | [.[].key]] + 
    # Then add peers with latest_handshake == 0 
    [(. | map(select(.value.latest_handshake == 0)) | [.[].key])] | 
    flatten | join(" ")) ' <<< "$json_data")
  
  # Use arrays instead of string concatenation
  local interface_output=()
  local peers_output=()

  local total_interface_rx=0
  local total_interface_tx=0

  interface_output+=("interface: $name")
  interface_output+=("  public key: $public_key")
  interface_output+=("  listening port: $listen_port")
  interface_output+=("  recorded since: $(time_diff $create_at)")
  interface_output+=("  last updated: $(time_diff $update_at)")

  for peer in $peers; do
    local endpoint allowed_ips latest_handshake total_rx total_tx
    read -r endpoint allowed_ips latest_handshake total_rx total_tx < <(
      jq -r ".peers[\"$peer\"] | \"\(.endpoint) \(.allowed_ips) \(.latest_handshake) \(.total_rx) \(.total_tx)\"" <<< "$json_data"
    )

    total_interface_rx=$((total_interface_rx + total_rx))
    total_interface_tx=$((total_interface_tx + total_tx))

    peers_output+=("")
    peers_output+=("peer: $peer")
    [[ "$endpoint" != "(none)" ]] && peers_output+=("  endpoint: $endpoint")
    peers_output+=("  allowed ips: $allowed_ips")
    [[ "$latest_handshake" -ne 0 ]] && peers_output+=("  latest handshake: $(time_diff $latest_handshake)")
    [[ $total_rx -ne 0 || $total_tx -ne 0 ]] && peers_output+=("  transfer: $(format_iec $total_rx) received, $(format_iec $total_tx) sent")
  done

  # Add total interface transfer
  interface_output+=("  transfer: $(format_iec $total_interface_rx) received, $(format_iec $total_interface_tx) sent")

  # Print the final output
  printf "%s\n" "${interface_output[@]}"
  printf "%s\n" "${peers_output[@]}"

  return 0
}

show_interface_colorized() {
  local interface_name="$1"
  [[ -z "$interface_name" ]] && return $ERR_INTERFACE_NAME_REQUIRED

  local file_path="$DB_PATH/$interface_name.json"
  [[ -f "$file_path" ]] || return $ERR_FILE_NOT_FOUND
  
  local json_data=$(<"$file_path")

  local name public_key listen_port create_at update_at peers
  read -r name public_key listen_port create_at update_at peers < <(jq -r '
    (.interface | "\(.name) \(.public_key) \(.listen_port) \(.create_at) \(.update_at) ") + 
    (.peers | to_entries | 
    [(. | map(select(.value.latest_handshake > 0))) | sort_by(.value.latest_handshake) | reverse | [.[].key]] + 
    # Then add peers with latest_handshake == 0 
    [(. | map(select(.value.latest_handshake == 0)) | [.[].key])] | 
    flatten | join(" ")) ' <<< "$json_data")
  
  # Use arrays instead of string concatenation
  local interface_output=()
  local peers_output=()

  local total_interface_rx=0
  local total_interface_tx=0

  interface_output+=("\e[1;32minterface:\e[0m \e[32m$name\e[0m")
  interface_output+=("  \e[1;37mpublic key:\e[0m \e[37m$public_key\e[0m")
  interface_output+=("  \e[1;37mlistening port:\e[0m \e[37m$listen_port\e[0m")
  interface_output+=("  \e[1;37mrecorded since:\e[0m \e[37m$(time_diff $create_at)\e[0m")
  interface_output+=("  \e[1;37mlast updated:\e[0m \e[37m$(time_diff $update_at)\e[0m")

  for peer in $peers; do
    local endpoint allowed_ips latest_handshake total_rx total_tx
    read -r endpoint allowed_ips latest_handshake total_rx total_tx < <(
      jq -r ".peers[\"$peer\"] | \"\(.endpoint) \(.allowed_ips) \(.latest_handshake) \(.total_rx) \(.total_tx)\"" <<< "$json_data"
    )

    total_interface_rx=$((total_interface_rx + total_rx))
    total_interface_tx=$((total_interface_tx + total_tx))

    peers_output+=("")
    peers_output+=("\e[1;33mpeer:\e[0m \e[33m$peer\e[0m")
    [[ "$endpoint" != "(none)" ]] && peers_output+=("  \e[1;37mendpoint:\e[0m \e[37m$endpoint\e[0m")
    peers_output+=("  \e[1;37mallowed ips:\e[0m \e[37m$allowed_ips\e[0m")
    [[ "$latest_handshake" -ne 0 ]] && peers_output+=("  \e[1;37mlatest handshake:\e[0m \e[37m$(time_diff $latest_handshake)\e[0m")
    [[ $total_rx -ne 0 || $total_tx -ne 0 ]] && peers_output+=("  \e[1;37mtransfer:\e[0m \e[37m$(format_iec $total_rx) received, $(format_iec $total_tx) sent\e[0m")
  done

  # Add total interface transfer
  interface_output+=("  \e[1;37mtransfer:\e[0m \e[37m$(format_iec $total_interface_rx) received, $(format_iec $total_interface_tx) sent\e[0m")

  # Print the final output
  printf "%b\n" "${interface_output[@]}"
  printf "%b\n" "${peers_output[@]}"

  return 0
}

show_interface_json() {
  local interface_name="$1"
  [[ -z "$interface_name" ]] && return $ERR_INTERFACE_NAME_REQUIRED
  local file_path="$DB_PATH/$interface_name.json"
  [[ -f "$file_path" ]] || return $ERR_FILE_NOT_FOUND
 
  local json_data=$(<"$file_path")
  local name public_key listen_port create_at update_at peers
  read -r name public_key listen_port create_at update_at peers < <(jq -r '
    (.interface | "\(.name) \(.public_key) \(.listen_port) \(.create_at) \(.update_at) ") +
    (.peers | to_entries |
    [(. | map(select(.value.latest_handshake > 0))) | sort_by(.value.latest_handshake) | reverse | [.[].key]] +
    # Then add peers with latest_handshake == 0
    [(. | map(select(.value.latest_handshake == 0)) | [.[].key])] |
    flatten | join(" ")) ' <<< "$json_data")
  
  # Initialize total interface transfer values
  local total_interface_rx=0
  local total_interface_tx=0

  # Generate JSON object for output
  local output_json=$(jq -n --arg name "$name" --arg public_key "$public_key" --arg listen_port "$listen_port" \
    --arg create_at "$(time_diff "$create_at")" --arg update_at "$(time_diff "$update_at")" \
    --argjson total_interface_rx "$total_interface_rx" --argjson total_interface_tx "$total_interface_tx" '
    {
      "interface": {
        "name": $name,
        "public_key": $public_key,
        "listen_port": $listen_port,
        "create_at": $create_at,
        "update_at": $update_at,
        "total_rx": $total_interface_rx,
        "total_tx": $total_interface_tx
      },
      "peers": {}
    }')
  # Modify peers value and append to the output JSON object
  for peer in $peers; do
    local endpoint allowed_ips latest_handshake total_rx total_tx
    read -r endpoint allowed_ips latest_handshake total_rx total_tx < <(
      jq -r ".peers[\"$peer\"] | \"\(.endpoint) \(.allowed_ips) \(.latest_handshake) \(.total_rx) \(.total_tx)\"" <<< "$json_data"
    )
    total_interface_rx=$((total_interface_rx + total_rx))
    total_interface_tx=$((total_interface_tx + total_tx))
    
    # Append peer data to the output JSON object, only including fields with meaningful values
    output_json=$(jq --arg peer "$peer" \
                     --arg allowed_ips "$allowed_ips" \
                     --arg endpoint "$endpoint" \
                     --arg handshake "$([ $latest_handshake -gt 0 ] && time_diff "$latest_handshake" || echo "")" \
                     --arg rx "$([ $total_rx -gt 0 ] && format_iec "$total_rx" || echo "")" \
                     --arg tx "$([ $total_tx -gt 0 ] && format_iec "$total_tx" || echo "")" '
                     .peers[$peer] = (
                       {
                         "allowed_ips": $allowed_ips,
                         "endpoint": $endpoint,
                         "latest_handshake": $handshake,
                         "total_rx": $rx,
                         "total_tx": $tx
                       } | with_entries(
                           select(
                             .value != null and
                             .value != "" and
                             .value != "(none)"
                           )
                         )
                     )' <<< "$output_json")
  done
  
  # Update the interface totals with formatted values
  output_json=$(jq --arg total_rx "$(format_iec $total_interface_rx)" \
                   --arg total_tx "$(format_iec $total_interface_tx)" '
                   .interface.total_rx = $total_rx | 
                   .interface.total_tx = $total_tx' <<< "$output_json")
    
  jq -r '.' <<< "$output_json"
  return 0
}

# Function to remove a WireGuard interface from the database
flush_interface() {
  local interface_name="$1"
  [[ -z "$interface_name" ]] && return $ERR_INTERFACE_NAME_REQUIRED

  local file_path="$DB_PATH/$interface_name.json"
  [[ ! -f "$file_path" ]] && return $ERR_FILE_NOT_FOUND

  rm "$file_path" || return $ERR_REMOVE_FAILED
  return 0
}

show_help() {
  cat <<EOF
Usage: $SCRIPT_NAME <cmd> [<args>]

Commands:
  show [<interface> | interfaces]  Show details of a specific WireGuard interface or list all interfaces.
                                     If 'interfaces' is provided, a list of all available interfaces will be displayed.
                                     If a specific interface name is provided, details of that interface will be shown.
                                     If no interface name is provided, details of all active interfaces will be shown.
  update [<interface>]             Update the configuration of a specific WireGuard interface.
                                     If a specific interface name is provided, that interface will be updated.
                                     If no interface name is provided, all active interfaces will be updated.
  flush <interface>                Remove the specified WireGuard interface from the database.
                                     The interface name is required for this command.
  help                             Show this help message with usage instructions.
EOF
}

handle_error() {
  local error_code=$1
  case $error_code in
    $ERR_UNKNOWN_COMMAND) ;; # echo "Error: Unknown command provided." >&2 
    $ERR_INTERFACE_NAME_REQUIRED) echo "Error: Interface name is required." >&2 ;;
    $ERR_INTERFACE_NOT_EXIST) echo "Error: Interface does not exist." >&2 ;;
    $ERR_JQ_PROCESSING) echo "Error: Failed to process JSON data with jq." >&2 ;;
    $ERR_FILE_NOT_FOUND) echo "Error: Interface does not exist." >&2 ;;
    $ERR_INVALID_TIMESTAMP) echo "Error: Invalid timestamp provided." >&2 ;;
    $ERR_INVALID_BYTES) echo "Error: Invalid byte value provided." >&2 ;;
    $ERR_REMOVE_FAILED) echo "Error: Failed to remove interface from database." >&2 ;;
    $ERR_ROOT_PRIVILEGE_REQUIRED) echo "Error: Root privileges are required." >&2 ;;
    $ERR_FILE_WRITE_FAILED) echo "Error: Failed to write to the file." >&2 ;;
    $ERR_NO_INTERFACES_FOUND) ;; # echo "Error: No WireGuard interfaces found." >&2
    *) echo "Error: An unknown error occurred." >&2 ;;
  esac
  exit $error_code
}

main() {
  local cmd="${1:-show}"
  local interface_name="${2:-all}"

  case "$cmd" in
    show)
      # Check user asked output with selected format(colorized, json), Default is colorized if supported
      local print_format=""
      [[ -t 1 ]] && print_format="colorized"
      if [ -n "$3" ]; then
        print_format="$3"
      fi
      
      if [[ $interface_name == "interfaces" ]]; then
        # Enable nullglob to ensure the pattern expands to nothing if no files match
        shopt -s nullglob
        interfaces=$(for file in "$DB_PATH"/*.json; do basename "$file" .json; done | tr '\n' ' ')
        [[ -z $interfaces ]] && handle_error $ERR_NO_INTERFACES_FOUND
        echo "$interfaces"
      elif [[ $print_format == "json" && $interface_name == "all" ]]; then
        # Enable nullglob to ensure the pattern expands to nothing if no files match
        shopt -s nullglob
        interfaces=$(for file in "$DB_PATH"/*.json; do basename "$file" .json; done | tr '\n' ' ')
        [[ -z $interfaces ]] && handle_error $ERR_NO_INTERFACES_FOUND
        # Initialize an empty array to hold all interface JSONs
        local combined_json='{"interfaces": []}'
        local interface_json=""
        # Process each interface and append its JSON to the array
        for iface in $interfaces; do
          interface_json=$(show_interface_json "$iface") || handle_error $?
          if [[ -n "$interface_json" ]]; then
            # Append the interface JSON to our array
            combined_json=$(jq --argjson interface "$interface_json" '.interfaces += [$interface]' <<< "$combined_json")
          fi
        done
        # Output the final JSON
        jq -r '.' <<< "$combined_json"
      elif [[ $print_format == "json" ]]; then
        show_interface_json "$interface_name" || handle_error $?
      elif [[ $print_format == "colorized" && $interface_name == "all" ]]; then
        # Enable nullglob to ensure the pattern expands to nothing if no files match
        shopt -s nullglob
        interfaces=$(for file in "$DB_PATH"/*.json; do basename "$file" .json; done | tr '\n' ' ')
        [[ -z $interfaces ]] && handle_error $ERR_NO_INTERFACES_FOUND
        local first=true
        for iface in $interfaces; do
          $first && first=false || echo "" # Adds a blank line before every interface except the first one
          show_interface_colorized "$iface"
          [ $? -eq 0 ] || handle_error $?
        done
      elif [[ $print_format == "colorized" ]]; then
        show_interface_colorized "$interface_name" || handle_error $?
      elif [[ $interface_name == "all" ]]; then
        # Enable nullglob to ensure the pattern expands to nothing if no files match
        shopt -s nullglob
        interfaces=$(for file in "$DB_PATH"/*.json; do basename "$file" .json; done | tr '\n' ' ')
        [[ -z $interfaces ]] && handle_error $ERR_NO_INTERFACES_FOUND
        local first=true
        for iface in $interfaces; do
          $first && first=false || echo "" # Adds a blank line before every interface except the first one
          show_interface "$iface"
          [ $? -eq 0 ] || handle_error $?
        done
      else
        show_interface "$interface_name" || handle_error $?
      fi
      ;;
    update)
      [ "$EUID" -eq 0 ] || handle_error $ERR_ROOT_PRIVILEGE_REQUIRED
      if [ "$interface_name" == "all" ]; then
        interfaces=$(wg show interfaces 2>/dev/null)
        [[ -z $interfaces ]] && handle_error $ERR_NO_INTERFACES_FOUND
        for iface in $interfaces; do
          { update_interface "$iface" && echo "Interface $iface updated at $(date '+%Y-%m-%d %H:%M:%S')" || handle_error $?; } &
        done
        wait  # Optionally, wait for all background jobs to finish.
      else
        update_interface "$interface_name" && echo "Interface $interface_name updated at $(date '+%Y-%m-%d %H:%M:%S')" || handle_error $?
      fi
      ;;
      
    flush)
      [ "$EUID" -eq 0 ] || handle_error $ERR_ROOT_PRIVILEGE_REQUIRED
      [[ -z "$interface_name" || "$interface_name" == "all" ]] && handle_error $ERR_INTERFACE_NAME_REQUIRED
      flush_interface "$interface_name" && echo "Interface $interface_name flushed at $(date '+%Y-%m-%d %H:%M:%S')" || handle_error $?
      ;;
      
    help)
      show_help
      ;;
      
    *)
      echo "Usage: $SCRIPT_NAME <cmd> [<args>]"
      echo "For more information on available commands, use '$SCRIPT_NAME help'."
      handle_error $ERR_UNKNOWN_COMMAND
      ;;
  esac

  return 0
}

main "$@"
exit 0