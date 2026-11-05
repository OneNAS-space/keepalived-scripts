#!/bin/sh
#
# /etc/keepalived/scripts/sync_dhcp.sh
#
# Keeps the Backup router in step with the Master:
#   1. dhcp.leases   (rsync, either direction)
#   2. /etc/config/dhcp, as a whole (hosts, tags, dnsmasq options, ...), except
#      the options this node's role scripts own, see KEEP_LOCAL below
#
# Layout of this file:
#   settings -> peer lookup -> helpers -> leases -> dhcp config -> daemon -> main

# Load OpenWrt UCI functions
. /lib/functions.sh

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
LOCAL_LEASES_FILE="/tmp/dhcp.leases"
SYNC_STATUS_FILE="/tmp/leases_sync_status"

DHCP_CONFIG="/etc/config/dhcp"
DHCP_CONFIG_DIR="/etc/config"
DHCP_VIEW_DIR="/tmp/.keepalived_dhcp_view"
DHCP_VIEW_NAME="ks_dhcp"
DHCP_BACKUP_COPY="/tmp/dhcp.pre-sync"
SELF_SCRIPT="/etc/keepalived/scripts/sync_dhcp.sh"
DHCP_PUSH_TIMEOUT=20
DHCP_PULL_TIMEOUT=8
# The keepalived package reloads dropbear on every node that turns Backup, so
# the peer of a new Master refuses ssh for a moment. A pull tries again for
# about PEER_RETRIES * PEER_RETRY_DELAY seconds before it gives up.
PEER_RETRIES=6
PEER_RETRY_DELAY=2

# Options that belong to the node's current role and are never taken from the
# peer nor sent to it: the Master/Backup switches that 560-keepalived-scripts
# sets on dhcp.lan. Written <section name>.<option>, for the whole option, or
# <section name>.<option>~<regex> for just the list entries whose value matches
# (the gateway and DNS entries of dhcp_option are the Master's VIP, any other
# entry in that list is ordinary config and is mirrored). More can be added
# with "list keep_local" in the sync section of /etc/config/keepalived_scripts. They are built in on purpose:
# an old config file without the list must not turn DHCP on on the Backup.
KEEP_LOCAL_DEFAULT="lan.ignore lan.dhcpv4 lan.force lan.dhcp_option~^(3|6|option:router|option:dns-server), lan.dhcpv6 lan.dhcpv6_pd lan.dhcpv6_pd_preferred lan.ra lan.ra_slaac lan.ra_preference lan.ra_flags lan.ntp"

# runtime state
DHCP_NO_RESTART=0
LAST_DHCP_HASH=""
DHCP_FAILED=0
DHCP_DID_PUSH=0

_add_keep_local() {
    KEEP_LOCAL="$KEEP_LOCAL $1"
}

load_config() {
    config_load keepalived_scripts
    config_get_bool ENABLE sync enable 0
    config_get INTERVAL sync interval 3600
    config_get RETRY_INTERVAL sync retry_interval 30
    config_get SSH_KEY sync ssh_key "/root/.ssh/id_dropbear"
    config_get USER_PEER_IP sync peer_ip
    config_get_bool SYNC_DHCP sync sync_dhcp 1
    KEEP_LOCAL="$KEEP_LOCAL_DEFAULT"
    config_list_foreach sync keep_local _add_keep_local
    SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
}

load_config

# ---------------------------------------------------------------------------
# Peer lookup
# ---------------------------------------------------------------------------
# Function to get the peer LAN IP from keepalived config
get_peer_lan_ip() {
    local lan_instance peer_name peer_ip
    config_load keepalived
    config_foreach find_lan_vrrp vrrp_instance

    if [ -z "$lan_instance" ]; then
        logger "sync_dhcp: Error: Could not find vrrp_instance with interface 'br-lan' in Keepalived configuration."
        return 1
    fi

    config_get peer_name "$lan_instance" unicast_peer
    if [ -z "$peer_name" ]; then
        logger "sync_dhcp: Error: Could not find unicast_peer for LAN vrrp_instance ($lan_instance) in Keepalived configuration."
        return 1
    fi

    config_foreach find_peer_address peer

    if [ -n "$peer_ip" ]; then
        echo "$peer_ip"
        return 0
    else
        logger "sync_dhcp: Error: Could not find IP address for peer ($peer_name)."
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

# Target peer: the lease_sync "peer_ip" option wins, otherwise the unicast
# peer of the br-lan vrrp_instance in the keepalived config
resolve_target_ip() {
    if [ -n "$USER_PEER_IP" ]; then
        echo "$USER_PEER_IP"
    else
        get_peer_lan_ip
    fi
}


# ---------------------------------------------------------------------------
# Helpers shared by the leases and dhcp-config parts
# ---------------------------------------------------------------------------
peer_up() {
    ping -c 1 -W 1 "$1" >/dev/null 2>&1
}

# Run a command on the peer through ssh with a watchdog, so a stuck peer
# cannot block the caller. Streams are files, because a background job would
# not get the caller's stdin.
#   remote_run <ip> <seconds> <command> <stdin file> <stdout file> <stderr file>
remote_run() {
    local pid wd rc

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "root@$1" "$3" < "$4" > "$5" 2> "$6" &
    pid=$!
    ( sleep "$2"; kill "$pid" 2>/dev/null ) &
    wd=$!
    wait "$pid"
    rc=$?
    kill "$wd" 2>/dev/null
    return "$rc"
}

# First line of an ssh/rsync error file that says something, without the
# notices dropbear prints on every call
err_text() {
    sed -e '/Ignoring unknown configuration option/d' \
        -e '/skipping hostkey check/d' \
        -e '/^[[:space:]]*$/d' \
        -e q "$1" 2>/dev/null
}

# retry_peer <stderr file> <command...>
# Runs the command again while it fails because the connection to the peer was
# refused or dropped (its sshd restarting). Success and any other failure end
# it at once. The error text of the last run stays in the stderr file, which
# the command itself must write.
retry_peer() {
    local errfile="$1"
    local tries=0 rc

    shift
    while :; do
        "$@"
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        tries=$((tries + 1))
        [ "$tries" -lt "$PEER_RETRIES" ] || return "$rc"
        grep -qiE 'refused|connect failed|timed out|no route|unreachable|reset by peer|connection (closed|lost)|lost connection' "$errfile" 2>/dev/null || return "$rc"
        sleep "$PEER_RETRY_DELAY"
    done
}

# ---------------------------------------------------------------------------
# Leases
# ---------------------------------------------------------------------------
# Function to pull leases from peer
# Runs in the foreground and is bounded by the ping check and the rsync
# timeout. The file is fetched to a temporary name first, so a failed or
# empty transfer never replaces the local leases.
rsync_from_peer() {
    rsync -az --timeout=10 -e "ssh $SSH_OPTS" "root@$1:$2" "$3" >/dev/null 2>"$4"
}

pull_leases() {
    local source_ip=$1
    local tmp_file="${LOCAL_LEASES_FILE}.pull.$$"
    local err_file="/tmp/.keepalived_leases_pull_err.$$"
    local CURRENT_HASH rc detail

    if [ -z "$source_ip" ]; then
        logger "sync_dhcp: Error: No peer IP given, skipping pull."
        return 1
    fi

    if ! peer_up "$source_ip"; then
        logger "sync_dhcp: Peer ($source_ip) is unreachable, skipping pull."
        return 1
    fi

    retry_peer "$err_file" rsync_from_peer "$source_ip" "$LOCAL_LEASES_FILE" "$tmp_file" "$err_file"
    rc=$?
    detail=$(err_text "$err_file")
    rm -f "$err_file"

    if [ "$rc" -eq 0 ] && [ -s "$tmp_file" ]; then
        mv -f "$tmp_file" "$LOCAL_LEASES_FILE"
        CURRENT_HASH=$(md5sum "$LOCAL_LEASES_FILE" 2>/dev/null | awk '{print $1}' 2>/dev/null)
        echo "$CURRENT_HASH" > "$SYNC_STATUS_FILE"
        return 0
    fi

    rm -f "$tmp_file"
    if [ "$rc" -eq 0 ]; then
        logger "sync_dhcp: Peer ($source_ip) has no leases to take over, keeping local leases."
    else
        logger "sync_dhcp: Error: Failed to pull DHCP leases from peer ($source_ip) (rc=$rc${detail:+: $detail}). Keeping local leases."
    fi
    return 1
}

# Function to push leases to peer
push_leases() {
    local dest_ip=$1
    local force_sync=$2
    local CURRENT_HASH
    local PREVIOUS_HASH

    if [ ! -s "$LOCAL_LEASES_FILE" ]; then
        logger "sync_dhcp: Local leases file $LOCAL_LEASES_FILE does not exist or is empty, skipping push."
        return 0
    fi

    CURRENT_HASH=$(md5sum "$LOCAL_LEASES_FILE" | awk '{print $1}' 2>/dev/null)

    if [ "$force_sync" != "force" ]; then
        if [ ! -f "$SYNC_STATUS_FILE" ]; then
            logger "sync_dhcp: First run or status file missing, performing push..."
        else
            PREVIOUS_HASH=$(cat "$SYNC_STATUS_FILE")
            if [ "$CURRENT_HASH" = "$PREVIOUS_HASH" ]; then
                return 0
            fi
        fi
    else
        logger "sync_dhcp: Force sync triggered (peer recovery), bypassing hash check."
    fi

    if ! peer_up "$dest_ip"; then
        return 1
    fi

    rsync -az --timeout=10 -e "ssh $SSH_OPTS" "$LOCAL_LEASES_FILE" "root@$dest_ip:$LOCAL_LEASES_FILE" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "$CURRENT_HASH" > "$SYNC_STATUS_FILE"
        return 0
    else
        logger "sync_dhcp: Error: Failed to push DHCP leases to peer host ($dest_ip)."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# dhcp config sync
#
# The Master's /etc/config/dhcp is mirrored to the Backup, whose DHCP server is
# off and whose LuCI therefore cannot edit hosts, tags and the like. Sections
# are copied whole (static hosts, tags with their dhcp_option, dnsmasq options,
# other interfaces) apart from the KEEP_LOCAL options, which stay as each node
# has them. The same function works in both directions: the Master pushes, a
# node that has just become Master pulls first. When both sides already match
# nothing is written and nothing is restarted.
#
# What is compared and sent is the "wire format": the committed config in one
# fixed layout, KEEP_LOCAL options removed.
# ---------------------------------------------------------------------------

# Committed dhcp config in one fixed layout (blank lines dropped, package
# line normalised). Read through a symlink under another package name: libuci
# still locks the file, but edits that are staged and not yet committed (LuCI
# "Save" without "Apply") are keyed by the package name "dhcp" and stay out.
dhcp_export_raw() {
    local raw

    mkdir -p "$DHCP_VIEW_DIR" || return 1
    ln -sf "$DHCP_CONFIG" "$DHCP_VIEW_DIR/$DHCP_VIEW_NAME" || return 1

    raw=$(uci -c "$DHCP_VIEW_DIR" -q export "$DHCP_VIEW_NAME") || return 1
    [ -n "$raw" ] || return 1

    printf '%s\n' "$raw" | awk '
        /^package / { print "package dhcp"; next }
        /^[[:space:]]*$/ { next }
        { print }
    '
}

# awk code shared by dhcp_strip and dhcp_keepers: kept(sect, line) says whether
# an option/list line belongs to this node (see KEEP_LOCAL)
DHCP_AWK_KEEP='
function setup(   n, a, i, t, j) {
    Q = sprintf("%c", 39); TAB = sprintf("%c", 9)
    item = "^" TAB "(option|list) "
    n = split(keep, a, " ")
    for (i = 1; i <= n; i++) {
        t = a[i]; j = index(t, "~")
        if (j) P[substr(t, 1, j - 1)] = substr(t, j + 1); else K[t] = 1
    }
}
function kept(sect, line,   key, v) {
    if (sect == "") return 0
    key = sect "." $2
    if (key in K) return 1
    if (key in P) { v = substr(line, index(line, Q) + 1); sub(Q "$", "", v); return (v ~ P[key]) }
    return 0
}
'

# stdin -> stdout without the KEEP_LOCAL options. A section that is left with
# nothing once they are gone is dropped too: apply_dhcp re-creates it from the
# node's own options, so both sides must not see it as a difference.
dhcp_strip() {
    awk -v keep="$KEEP_LOCAL" "$DHCP_AWK_KEEP"'
        function head() { if (hdr != "") { if (!(removed && !shown)) print hdr; hdr = "" } }
        BEGIN { setup() }
        /^[[:space:]]*$/ { next }
        /^config / { head(); hdr = $0; sect = ""; removed = 0; shown = 0; if (split($0, p, Q) >= 3) sect = p[2]; next }
        $0 ~ item  {
            if (kept(sect, $0)) { removed = 1; next }
            if (hdr != "") { print hdr; hdr = "" }
            shown = 1; print; next
        }
        { print }
        END { head() }
    '
}

# The wire format of this node
dhcp_export() {
    local raw

    raw=$(dhcp_export_raw) || return 1
    printf '%s\n' "$raw" | dhcp_strip
}

# The KEEP_LOCAL options of this node, each under its section header
dhcp_keepers() {
    dhcp_export_raw | awk -v keep="$KEEP_LOCAL" "$DHCP_AWK_KEEP"'
        BEGIN { setup() }
        /^config / { hdr = $0; sect = ""; shown = 0; if (split($0, p, Q) >= 3) sect = p[2]; next }
        $0 ~ item  { if (kept(sect, $0)) { if (!shown) { print hdr; shown = 1 }; print } }
    '
}

# dhcp_merge <keepers file> <incoming file>: the incoming sections with this
# node's own KEEP_LOCAL options put back into their sections (a section the
# incoming config lacks is re-created with just those options)
dhcp_merge() {
    awk -v keepfile="$1" '
        function flush(h) {
            if (h != "" && (h in L) && !(h in done)) { printf "%s", L[h]; done[h] = 1 }
        }
        BEGIN {
            while ((getline line < keepfile) > 0) {
                if (line ~ /^config /) { cur = line; order[++nk] = line; L[cur] = "" }
                else L[cur] = L[cur] line "\n"
            }
        }
        /^config / { flush(last); last = $0; print; next }
        { print }
        END {
            flush(last)
            for (i = 1; i <= nk; i++) if (!(order[i] in done)) { print order[i]; printf "%s", L[order[i]] }
        }
    ' "$2"
}

# Order-insensitive form of a config, for comparing only: sections sorted,
# and inside a section the options sorted by name. Save & Apply in LuCI may
# reorder sections and options without changing anything; that must not count
# as a difference. The order of the items of one list is kept (it matters).
dhcp_canon() {
    awk '
        BEGIN { n = 0 }
        /^config / { n++; printf "%d||0|%s\n", n, $0; next }
        { split($0, w, " "); printf "%d|%s|%d|%s\n", n, w[2], NR, $0 }
    ' | LC_ALL=C sort -t '|' -k1,1n -k2,2 -k3,3n | awk -F '|' '
        {
            line = $0; sub(/^[^|]*\|[^|]*\|[^|]*\|/, "", line)
            if ($1 != cur) { if (cur != "") print buf; cur = $1; buf = line }
            else buf = buf "\001" line
        }
        END { if (cur != "") print buf }
    ' | LC_ALL=C sort | tr '\001' '\n'
}

dhcp_hash() {
    dhcp_canon | md5sum | awk '{print $1}'
}

# The receiving side accepts nothing but what dhcp_export prints: a package
# line, then sections made of option/list lines.
valid_dhcp_blob() {
    awk '
        BEGIN {
            Q = sprintf("%c", 39); TAB = sprintf("%c", 9)
            item = "^" TAB "(option|list) [A-Za-z0-9_]+ "
            sect = "^config [A-Za-z0-9_]+( " Q "[^" Q "]*" Q ")?$"
        }
        NR == 1 { if ($0 != "package dhcp") bad = 1; next }
        /^$/ { next }
        $0 ~ sect { seen = 1; next }
        $0 ~ item { if (!seen) bad = 1; next }
        { bad = 1 }
        END { if (NR == 0) bad = 1; exit bad }
    ' "$1"
}

# Log a sync error once, not on every retry
dhcp_log_err() {
    [ "$DHCP_FAILED" -eq 1 ] || logger "sync_dhcp: $*"
}

restart_dhcp_services() {
    /etc/init.d/dnsmasq running >/dev/null 2>&1 && { /etc/init.d/dnsmasq restart >/dev/null 2>&1 || logger "sync_dhcp: Error restarting dnsmasq after the dhcp config update."; }
    /etc/init.d/odhcpd running >/dev/null 2>&1 && { /etc/init.d/odhcpd restart >/dev/null 2>&1 || logger "sync_dhcp: Error restarting odhcpd after the dhcp config update."; }
    return 0
}

# Receiving side (run locally by pull_dhcp, or through ssh by push_dhcp): the
# wire format arrives on stdin. Prints "unchanged" or "updated" and exits 0, or
# prints the reason and fails: 1 rejected/failed, 4 sync off here, 5 there are
# uncommitted dhcp changes on this node.
apply_dhcp() {
    local in_file="/tmp/.keepalived_dhcp_in.$$"
    local cur_file="/tmp/.keepalived_dhcp_cur.$$"
    local keep_file="/tmp/.keepalived_dhcp_keep.$$"
    local new_file="/tmp/.keepalived_dhcp_new.$$"
    local in_hash cur_hash keep_hash failed=0

    if [ "$SYNC_DHCP" -ne 1 ]; then
        echo "dhcp config sync is disabled on this node (keepalived_scripts.sync.sync_dhcp)"
        return 4
    fi

    cat > "$in_file"
    if ! valid_dhcp_blob "$in_file"; then
        rm -f "$in_file"
        echo "rejected: the input is not a plain dhcp config"
        return 1
    fi

    # whatever the sender did, this node's own options never come from outside
    dhcp_strip < "$in_file" > "$new_file"
    mv -f "$new_file" "$in_file"

    if ! dhcp_export > "$cur_file"; then
        rm -f "$in_file" "$cur_file"
        echo "cannot read the local $DHCP_CONFIG"
        return 1
    fi

    in_hash=$(dhcp_hash < "$in_file")
    cur_hash=$(dhcp_hash < "$cur_file")
    rm -f "$cur_file"

    if [ "$in_hash" = "$cur_hash" ]; then
        rm -f "$in_file"
        echo "unchanged"
        return 0
    fi

    # A commit of "dhcp" would also commit whatever somebody has staged but
    # not committed yet. Do not do that behind their back; try again later.
    if [ -n "$(uci -q changes dhcp 2>/dev/null)" ]; then
        rm -f "$in_file"
        echo "not applied: there are uncommitted changes in dhcp on this node"
        return 5
    fi

    # The configs really differ: keep a copy in RAM, then replace the package
    # (own options put back in)
    cp "$DHCP_CONFIG" "$DHCP_BACKUP_COPY" 2>/dev/null
    dhcp_keepers > "$keep_file"
    keep_hash=$(dhcp_hash < "$keep_file")
    dhcp_merge "$keep_file" "$in_file" > "$new_file"
    rm -f "$in_file"

    uci -q import dhcp < "$new_file" && uci -q commit dhcp || failed=1
    rm -f "$new_file"

    if [ "$failed" -ne 0 ]; then
        uci -q revert dhcp
        rm -f "$keep_file"
        echo "failed to write the dhcp config into $DHCP_CONFIG"
        return 1
    fi

    if [ "$(dhcp_export | dhcp_hash)" != "$in_hash" ] || [ "$(dhcp_keepers | dhcp_hash)" != "$keep_hash" ]; then
        logger "sync_dhcp: dhcp config written, but reading it back gives a different result."
    fi
    rm -f "$keep_file"
    logger "sync_dhcp: dhcp config updated from the peer, previous $DHCP_CONFIG saved as $DHCP_BACKUP_COPY"

    # only when something really changed (and not when the caller restarts
    # the services anyway, see pull_dhcp)
    [ "$DHCP_NO_RESTART" -eq 1 ] || restart_dhcp_services

    echo "updated"
    return 0
}

# Sending side, run on the Master. Pushes only when the config changed since
# the last successful push, or when force is 1 (daemon start, peer came back,
# periodic re-check). The peer then compares for itself and skips the write if
# it already matches. Returns 1 when it could not be done.
push_dhcp() {
    local dest_ip=$1
    local force=$2
    local blob_file="/tmp/.keepalived_dhcp_blob.$$"
    local out_file="/tmp/.keepalived_dhcp_out.$$"
    local cur_hash result rc count

    if ! dhcp_export > "$blob_file"; then
        rm -f "$blob_file"
        dhcp_log_err "Error: cannot read the dhcp config from $DHCP_CONFIG."
        return 1
    fi

    cur_hash=$(dhcp_hash < "$blob_file")
    if [ "$force" != "1" ] && [ "$cur_hash" = "$LAST_DHCP_HASH" ]; then
        rm -f "$blob_file"
        return 0
    fi

    if ! peer_up "$dest_ip"; then
        rm -f "$blob_file"
        dhcp_log_err "Peer ($dest_ip) is unreachable, dhcp config not pushed."
        return 1
    fi

    DHCP_DID_PUSH=1
    remote_run "$dest_ip" "$DHCP_PUSH_TIMEOUT" "$SELF_SCRIPT apply_dhcp" "$blob_file" "$out_file" "$out_file.err"
    rc=$?

    result=$(head -n 1 "$out_file" 2>/dev/null)
    [ -n "$result" ] || result=$(err_text "$out_file.err")
    count=$(grep -c "^config host" "$blob_file")
    rm -f "$blob_file" "$out_file" "$out_file.err"

    if [ "$rc" -ne 0 ]; then
        dhcp_log_err "Error: pushing the dhcp config to peer ($dest_ip) failed (exit $rc): ${result:-no output}"
        return 1
    fi

    LAST_DHCP_HASH="$cur_hash"
    if [ "$result" = "updated" ]; then
        logger "sync_dhcp: Pushed the dhcp config ($count host entries), the peer ($dest_ip) was updated."
    fi
    return 0
}

# Run on a node that has just become Master, before its DHCP server starts:
# take over the peer's config first. The peer was Master until now, so it may
# hold edits this node has not seen. Same rule as everywhere else: written
# only when they differ. "norestart": the caller restarts the services itself.
# Any problem leaves the local config as it is.
pull_dhcp() {
    local source_ip=$1
    local norestart=$2
    local in_file="/tmp/.keepalived_dhcp_pull.$$"
    local err_file="/tmp/.keepalived_dhcp_pull_err.$$"
    local rc result detail

    [ "$SYNC_DHCP" -eq 1 ] || return 0

    if [ -z "$source_ip" ]; then
        logger "sync_dhcp: Error: No peer IP given, dhcp config not pulled."
        return 1
    fi

    if ! peer_up "$source_ip"; then
        logger "sync_dhcp: Peer ($source_ip) is unreachable, keeping the local dhcp config."
        return 1
    fi

    retry_peer "$err_file" remote_run "$source_ip" "$DHCP_PULL_TIMEOUT" "$SELF_SCRIPT export_dhcp" /dev/null "$in_file" "$err_file"
    rc=$?
    detail=$(err_text "$err_file")
    rm -f "$err_file"

    if [ "$rc" -ne 0 ]; then
        rm -f "$in_file"
        logger "sync_dhcp: Could not read the dhcp config from peer ($source_ip) (rc=$rc${detail:+: $detail}), keeping the local one."
        return 1
    fi
    if ! valid_dhcp_blob "$in_file"; then
        rm -f "$in_file"
        logger "sync_dhcp: The dhcp config sent by peer ($source_ip) is not valid, keeping the local one."
        return 1
    fi

    # A peer without a single host/tag (reset, new hardware) must not wipe ours
    if ! grep -Eq '^config (host|tag)' "$in_file" && dhcp_export 2>/dev/null | grep -Eq '^config (host|tag)'; then
        rm -f "$in_file"
        logger "sync_dhcp: Peer ($source_ip) has no host/tag entries, keeping the local dhcp config."
        return 1
    fi

    [ "$norestart" = "norestart" ] && DHCP_NO_RESTART=1
    result=$(apply_dhcp < "$in_file")
    rc=$?
    DHCP_NO_RESTART=0
    rm -f "$in_file"

    if [ "$rc" -ne 0 ]; then
        logger "sync_dhcp: dhcp config of peer ($source_ip) not taken over: $result"
        return 1
    fi
    if [ "$result" = "updated" ]; then
        logger "sync_dhcp: Took over the dhcp config of peer ($source_ip)."
    fi
    return 0
}

# Did the config change since the last successful push?
dhcp_changed() {
    local now

    now=$(dhcp_export 2>/dev/null) || return 1
    now=$(printf '%s\n' "$now" | dhcp_hash)
    [ -n "$now" ] && [ "$now" != "$LAST_DHCP_HASH" ]
}

# ---------------------------------------------------------------------------
# Daemon (procd, see /etc/init.d/lease_sync)
# ---------------------------------------------------------------------------
daemon_push() {
    logger "sync_dhcp: Background service starting..."
    local CACHED_PEER_IP=""
    local SYNC_FAILED=0
    local WATCH_FAILED=0
    local WATCH_RC
    local DHCP_FORCE=1
    local WAIT

    # procd stops this service by signalling only this shell, which would leave
    # a running inotifywait behind (parent pid 1) until its timeout. The watch
    # therefore runs in the background and the trap ends it with the daemon.
    WATCH_PID=""
    trap '[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null; exit 0' TERM INT

    while true; do
        load_config
        if [ "$ENABLE" -ne 1 ]; then
            logger "sync_dhcp: Service disabled via UCI, exiting."
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
            local sync_mode=""
            if [ "$SYNC_FAILED" -eq 1 ]; then
                sync_mode="force"
            fi
            
            if ! push_leases "$TARGET_IP" "$sync_mode"; then
                CACHED_PEER_IP=""
                SYNC_FAILED=1
                sleep "$RETRY_INTERVAL"
                continue
            else
                SYNC_FAILED=0
            fi
        fi

        # dhcp config. A failure here never touches the lease logic above;
        # it only shortens the wait below so the push is retried soon.
        DHCP_DID_PUSH=0
        if [ "$SYNC_DHCP" -eq 1 ] && [ -n "$TARGET_IP" ]; then
            # the peer was unreachable a moment ago: send everything again
            [ "$sync_mode" = "force" ] && DHCP_FORCE=1
            if push_dhcp "$TARGET_IP" "$DHCP_FORCE"; then
                [ "$DHCP_FAILED" -eq 1 ] && logger "sync_dhcp: dhcp config sync works again."
                DHCP_FAILED=0
                DHCP_FORCE=0
            else
                DHCP_FAILED=1
            fi
        fi

        # Config edited while the push was running would otherwise wait for
        # the next event: look once more before going to sleep.
        if [ "$DHCP_DID_PUSH" -eq 1 ] && [ "$DHCP_FAILED" -eq 0 ] && dhcp_changed; then
            continue
        fi

        WAIT="$INTERVAL"
        [ "$DHCP_FAILED" -eq 1 ] && WAIT="$RETRY_INTERVAL"

        # exit status: 0 = something changed, 2 = timeout (periodic re-check),
        # anything else = inotifywait missing, or the watched file not there yet.
        # Wait before retrying in that case, otherwise this loop would spin.
        # With dhcp sync on, /etc/config is watched too, but only for the
        # file "dhcp": edits made with uci/LuCI write it in place or replace it.
        if [ "$SYNC_DHCP" -eq 1 ]; then
            inotifywait -t "$WAIT" -e modify,close_write,moved_to,create \
                --include '/(dhcp|dhcp\.leases)$' \
                "$LOCAL_LEASES_FILE" "$DHCP_CONFIG_DIR" >/dev/null 2>&1 &
        else
            inotifywait -t "$WAIT" -e modify "$LOCAL_LEASES_FILE" >/dev/null 2>&1 &
        fi
        WATCH_PID=$!
        wait "$WATCH_PID"
        WATCH_RC=$?
        WATCH_PID=""
        case "$WATCH_RC" in
            0)
                WATCH_FAILED=0
                sleep 2
                ;;
            2)
                # periodic re-check: let the peer confirm it still matches
                WATCH_FAILED=0
                DHCP_FORCE=1
                ;;
            *)
                if [ "$WATCH_FAILED" -eq 0 ]; then
                    logger "sync_dhcp: inotifywait failed (exit $WATCH_RC): is it installed and does $LOCAL_LEASES_FILE exist? Retrying every ${RETRY_INTERVAL}s."
                fi
                WATCH_FAILED=1
                sleep "$RETRY_INTERVAL"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# pull/push without an IP use the configured or keepalived peer
case "$1" in
    daemon_push)
        daemon_push ;;
    get_peer_ip)
        get_peer_lan_ip ;;
    pull)
        pull_leases "${2:-$(resolve_target_ip)}" ;;
    push)
        push_leases "${2:-$(resolve_target_ip)}" ;;
    push_dhcp)
        # manual run: always asks the peer, prints nothing on success
        push_dhcp "${2:-$(resolve_target_ip)}" 1 ;;
    pull_dhcp)
        # new Master: take over the peer's config; $3 = norestart when the
        # caller restarts dnsmasq/odhcpd itself. $2 may be empty (configured peer).
        pull_dhcp "${2:-$(resolve_target_ip)}" "$3" ;;
    apply_dhcp)
        # receiving side, called through ssh by push_dhcp
        apply_dhcp ;;
    export_dhcp)
        # called through ssh by pull_dhcp on the peer
        dhcp_export ;;
    *)
        logger "sync_dhcp: Usage: $0 [pull|push|push_dhcp|pull_dhcp|apply_dhcp|export_dhcp|daemon_push|get_peer_ip]"
        exit 1 ;;
esac
