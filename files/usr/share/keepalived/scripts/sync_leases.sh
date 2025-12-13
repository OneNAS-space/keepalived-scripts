#!/bin/sh

# Load OpenWrt UCI functions
. /lib/functions.sh

# Define flag file
LOCAL_LEASES_FILE="/tmp/dhcp.leases"
SYNC_STATUS_FILE="/tmp/leases_sync_status"

# Function to get the peer LAN IP from keepalived config
get_peer_lan_ip() {
    local lan_instance peer_name peer_ip

    config_load keepalived
    config_foreach find_lan_vrrp vrrp_instance

    if [ -z "$lan_instance" ]; then
        logger "sync_leases: Error: Could not find vrrp_instance with interface 'br-lan' in Keepalived configuration."
        return 1
    fi

    config_get peer_name "$lan_instance" unicast_peer
    if [ -z "$peer_name" ]; then
        logger "sync_leases: Error: Could not find unicast_peer for LAN vrrp_instance ($lan_instance) in Keepalived configuration."
        return 1
    fi

    config_foreach find_peer_address peer

    if [ -n "$peer_ip" ]; then
        echo "$peer_ip"
        return 0
    else
        logger "sync_leases: Error: Could not find IP address for peer ($peer_name)."
        return 1
    fi
}

find_lan_vrrp() {
    local section="$1"
    local iface
    config_get iface "$section" interface
    [ "$iface" = "br-lan" ] && lan_instance="$section"
}

find_peer_address() {
    local section="$1"
    local name
    config_get name "$section" name
    if [ "$name" = "$peer_name" ]; then
        config_get peer_ip "$section" address
    fi
}

# Added: Directly return peer IP for external calls
if [ "$1" = "get_peer_ip" ]; then
    get_peer_lan_ip
    exit $?
fi

PEER_IP=$(get_peer_lan_ip)

if [ -z "$PEER_IP" ]; then
    logger "sync_leases: Error: Could not determine peer LAN IP, exiting sync."
    exit 1
fi

# Function to pull leases from peer
pull_leases() {
    local source_ip=$1
    rsync -az --timeout=10 "root@$source_ip:$LOCAL_LEASES_FILE" "$LOCAL_LEASES_FILE" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        logger "sync_leases: Successfully pulled DHCP leases from peer ($source_ip)."
        # After successful pull, update the hash in the status file
        CURRENT_HASH=$(md5sum "$LOCAL_LEASES_FILE" 2>/dev/null | awk '{print $1}')
        echo "$CURRENT_HASH" > "$SYNC_STATUS_FILE"
        return 0
    else
        logger "sync_leases: Error: Failed to pull DHCP leases from peer ($source_ip)."
        return 1
    fi
}

# Function to push leases to peer
push_leases() {
    local dest_ip=$1

    # Check if local leases file exists and is not empty
    if [ ! -s "$LOCAL_LEASES_FILE" ]; then # -s checks if file exists and is not empty
        logger "sync_leases: Local leases file $LOCAL_LEASES_FILE does not exist or is empty, skipping push."
        exit 0
    fi

    # Compute current leases file hash
    CURRENT_HASH=$(md5sum "$LOCAL_LEASES_FILE" | awk '{print $1}')

    # If the status file does not exist, initialize it
    if [ ! -f "$SYNC_STATUS_FILE" ]; then
        logger "sync_leases: First run or status file missing, performing push..."
    else
        # Read the hash from the last sync
        PREVIOUS_HASH=$(cat "$SYNC_STATUS_FILE")
        # If hashes are the same, file hasn't changed, no need to sync
        if [ "$CURRENT_HASH" = "$PREVIOUS_HASH" ]; then
            exit 0
        fi
    fi

    rsync -az --timeout=10 "$LOCAL_LEASES_FILE" "root@$dest_ip:$LOCAL_LEASES_FILE" >/dev/null 2>&1

    # Check the result of the rsync command
    if [ $? -eq 0 ]; then
        logger "sync_leases: Successfully pushed DHCP leases to peer host ($dest_ip)."
        # After successful sync, update the hash in the status file
        echo "$CURRENT_HASH" > "$SYNC_STATUS_FILE"
        return 0
    else
        logger "sync_leases: Error: Failed to push DHCP leases to peer host ($dest_ip)."
        return 1
    fi
}

# Main logic based on arguments
case "$1" in
    pull)
        pull_leases "$PEER_IP"
        ;;
    push)
        push_leases "$PEER_IP"
        ;;
    *)
        logger "sync_leases: Usage: $0 [pull|push|get_peer_ip]"
        exit 1
        ;;
esac

exit 0
