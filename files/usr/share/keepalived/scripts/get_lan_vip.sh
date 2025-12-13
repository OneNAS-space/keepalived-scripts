#!/bin/sh

LOG_TAG="GET_VIP_SCRIPT"

get_lan_vip() {
    local lan_instance_line=$(uci show keepalived 2>/dev/null | grep "@vrrp_instance" | grep "interface='br-lan'")
    if [ -z "$lan_instance_line" ]; then
        logger "$LOG_TAG: ERROR: Could not find vrrp_instance for interface 'br-lan'."
        return 1
    fi
    local lan_instance_key=$(echo "$lan_instance_line" | cut -d'=' -f 1 | cut -d'.' -f 1,2)
    local ip_ref=$(uci get "${lan_instance_key}.virtual_ipaddress" 2>/dev/null)

    local ip_section_line=$(uci show keepalived 2>/dev/null | grep "@ipaddress" | grep "name='${ip_ref}'")
    if [ -z "$ip_section_line" ]; then
        logger "$LOG_TAG: ERROR: Could not find @ipaddress section matching reference '${ip_ref}'."
        return 1
    fi
    local ip_section_key=$(echo "$ip_section_line" | cut -d'=' -f 1 | cut -d'.' -f 1,2)
    local vip_raw=$(uci get "${ip_section_key}.address" 2>/dev/null)
    if [ -z "$vip_raw" ]; then
        logger "$LOG_TAG: ERROR: Could not retrieve LAN VIP from UCI config (address field empty)."
        return 1
    fi
    local VIP=$(echo "$vip_raw" | cut -d/ -f1)
    echo "$VIP"
    return 0
}

get_lan_vip
