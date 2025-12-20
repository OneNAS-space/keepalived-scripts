#!/bin/sh

# Load OpenWrt UCI functions
. /lib/functions.sh

# Define flag file
LOCAL_LEASES_FILE="/tmp/dhcp.leases"
SYNC_STATUS_FILE="/tmp/leases_sync_status"

load_config() {
    config_load lease_sync
    config_get_bool ENABLE global enable 0
    config_get INTERVAL global interval 3600
    config_get SSH_KEY global ssh_key "/root/.ssh/id_dropbear"
    config_get USER_PEER_IP global peer_ip
}

load_config

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
    if [ "$iface" = "br-lan" ]; then
        lan_instance="$section"
    fi
}

find_peer_address() {
    local section="$1"
    local name
    config_get name "$section" name
    if [ "$name" = "$peer_name" ]; then
        config_get peer_ip "$section" address
    fi
}

# Function to pull leases from peer
pull_leases() {
    local source_ip=$1
    rsync -az --timeout=10 -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "root@$source_ip:$LOCAL_LEASES_FILE" "$LOCAL_LEASES_FILE" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        logger "sync_leases: Successfully pulled DHCP leases from peer ($source_ip)."
        local CURRENT_HASH=$(md5sum "$LOCAL_LEASES_FILE" 2>/dev/null | awk '{print $1}' 2>/dev/null)
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
    if [ ! -s "$LOCAL_LEASES_FILE" ]; then
        logger "sync_leases: Local leases file $LOCAL_LEASES_FILE does not exist or is empty, skipping push."
        return 0
    fi

    local CURRENT_HASH=$(md5sum "$LOCAL_LEASES_FILE" | awk '{print $1}' 2>/dev/null)

    if [ ! -f "$SYNC_STATUS_FILE" ]; then
        logger "sync_leases: First run or status file missing, performing push..."
    else
        local PREVIOUS_HASH=$(cat "$SYNC_STATUS_FILE")
        if [ "$CURRENT_HASH" = "$PREVIOUS_HASH" ]; then
            return 0
        fi
    fi

    if ! ping -c 1 -W 1 "$dest_ip" >/dev/null 2>&1; then
        return 1
    fi

    rsync -az --timeout=10 -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$LOCAL_LEASES_FILE" "root@$dest_ip:$LOCAL_LEASES_FILE" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        logger "sync_leases: Successfully pushed DHCP leases to peer host ($dest_ip)."
        echo "$CURRENT_HASH" > "$SYNC_STATUS_FILE"
        return 0
    else
        logger "sync_leases: Error: Failed to push DHCP leases to peer host ($dest_ip)."
        return 1
    fi
}

daemon_push() {
    logger "sync_leases: Background service starting..."
    local CACHED_PEER_IP=""
    while true; do
        load_config
        if [ "$ENABLE" -ne 1 ]; then
            logger "sync_leases: Service disabled via UCI, exiting."
            break
        fi

        local TARGET_IP="$USER_PEER_IP"
        if [ -z "$TARGET_IP" ]; then
            if [ -z "$CACHED_PEER_IP" ]; then
                CACHED_PEER_IP=$(get_peer_lan_ip)
            fi
            TARGET_IP="$CACHED_PEER_IP"
        fi

        if [ -n "$TARGET_IP" ]; then
            if ! push_leases "$TARGET_IP"; then
                CACHED_PEER_IP=""
                sleep 5
            fi
        fi

        inotifywait -t "$INTERVAL" -e modify "$LOCAL_LEASES_FILE" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            sleep 2
        fi
    done
}

# Main logic based on arguments
case "$1" in
    daemon_push)
        daemon_push ;;
    get_peer_ip)
        get_peer_lan_ip ;;
    pull)
        pull_leases "$2" ;;
    push)
        push_leases "$2" ;;
    *)
        logger "sync_leases: Usage: $0 [pull|push|daemon_push|get_peer_ip]"
        exit 1 ;;
esac
