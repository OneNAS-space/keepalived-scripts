#!/bin/sh

# SCRIPT: agh_bind_hosts.sh
# DESCRIPTION: Safely adds or removes the Keepalived Virtual IP (VIP)
#              from the AdGuard Home configuration file's 'dns.bind_hosts' list.
# USAGE:       ./agh_bind_hosts.sh [add|remove]
# DEPENDS:     /user/share/keepalived/scripts/get_lan_vip.sh

LOG_TAG="AGH_BIND_HOSTS"
ADGUARD_YAML="/etc/AdGuardHome.yaml"

VIP_SCRIPT="/etc/keepalived/scripts/get_lan_vip.sh"

BIND_HOSTS_KEY="  bind_hosts:"
INDENT="    - "

get_vip_or_exit() {
    local VIP
    VIP=$("$VIP_SCRIPT")

    if [ $? -ne 0 ] || [ -z "$VIP" ]; then
        logger "$LOG_TAG: FATAL ERROR: Failed to get VIP for YAML modification."
        return 1 
    fi
    echo "$VIP"
    return 0
}

modify_bind_hosts() {
    local ACTION=$1
    local CURRENT_VIP
    
    CURRENT_VIP=$(get_vip_or_exit)
    if [ $? -ne 0 ]; then
        return 1
    fi
    local VIP_ENTRY="${INDENT}${CURRENT_VIP}"

    logger "$LOG_TAG: Attempting to $ACTION VIP ($CURRENT_VIP) in YAML."

    if [ ! -f "$ADGUARD_YAML" ]; then
        logger "$LOG_TAG: ERROR: AdGuardHome YAML file not found at $ADGUARD_YAML"
        return 1
    fi

    if grep -q "$CURRENT_VIP" "$ADGUARD_YAML"; then
        sed -i "/${VIP_ENTRY}/d" "$ADGUARD_YAML"
        logger "$LOG_TAG: Cleaned existing VIP entry: $VIP_ENTRY."
    fi

    if [ "$ACTION" = "add" ]; then
        local BIND_HOSTS_LINE_NUM=$(grep -n "$BIND_HOSTS_KEY" "$ADGUARD_YAML" | cut -d: -f 1)
        if [ -z "$BIND_HOSTS_LINE_NUM" ]; then
            logger "$LOG_TAG: FATAL ERROR: Could not find '$BIND_HOSTS_KEY' section in YAML. Cannot add VIP."
            return 1
        fi

        local FIRST_ITEM_LINE=$(grep -n "$INDENT" "$ADGUARD_YAML" | grep -A 1 "$BIND_HOSTS_KEY" | grep "$INDENT" | head -n 1 | cut -d: -f 1)
        local INSERT_LINE_NUM
        if [ -n "$FIRST_ITEM_LINE" ]; then
            INSERT_LINE_NUM="$FIRST_ITEM_LINE"
        else
            INSERT_LINE_NUM="$BIND_HOSTS_LINE_NUM"
        fi

        sed -i "${INSERT_LINE_NUM}a\\
${VIP_ENTRY}" "$ADGUARD_YAML"

        logger "$LOG_TAG: Successfully added new VIP entry: $VIP_ENTRY."
    elif [ "$ACTION" = "remove" ]; then
        logger "$LOG_TAG: Remove action complete (VIP entry is now cleaned)."
    fi
    
    return 0
}

if [ -z "$1" ]; then
    logger "$LOG_TAG: Usage: $0 [add|remove] - Missing argument."
    exit 1
fi

ACTION_PARAM=$(echo "$1" | tr '[:upper:]' '[:lower:]')

if [ "$ACTION_PARAM" = "add" ] || [ "$ACTION_PARAM" = "remove" ]; then
    modify_bind_hosts "$ACTION_PARAM"
    exit $?
else
    logger "$LOG_TAG: Invalid argument '$1'. Use 'add' or 'remove'."
    exit 1
fi
