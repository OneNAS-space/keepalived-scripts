/* Shared by Role Actions (settings), the Status > VRRP tab and the Status overview card:
 * what 560-keepalived-scripts follows, the state it is in, and what each service gets in it. */
'use strict';
'require baseclass';
'require uci';
'require rpc';

const CONFIG = 'keepalived_scripts';

/* service -> [ title, what each action does ]. The same text in every tab. */
const SERVICES = {
	dhcpv4: [ _('DHCPv4'), {
		on: _('The DHCPv4 server of the LAN is switched on and hands out the LAN VIP as gateway and DNS.'),
		off: _('The DHCPv4 server of the LAN is switched off and the gateway/DNS options are removed.'),
		keep: _('The DHCPv4 server of the LAN is left as it is.') } ],
	dnsmasq: [ _('Dnsmasq'), {
		on: _('dnsmasq is running: started if it was stopped, restarted when DHCPv4 or the leases changed.'),
		off: _('dnsmasq is stopped, so the router itself has no resolver and needs another upstream DNS. Needs the keepalived-sync patch that stops 551-dnsmasq from touching dnsmasq, otherwise both fight over it.'),
		keep: _('dnsmasq is neither started nor stopped; it is restarted only when it is running and DHCPv4 or the leases changed.') } ],
	natmap: [ _('Natmap'), {
		on: _('Enabled in its config and started.'),
		off: _('Disabled in its config and stopped.'),
		keep: _('Left as it is.') } ],
	lease_sync: [ _('Lease sync'), {
		on: _('The lease sync service runs: the leases and the DHCP config of this node are pushed to the peer (see the Lease sync tab).'),
		off: _('The lease sync service is stopped.'),
		keep: _('The lease sync service is left as it is.') } ],
	dhcpv6: [ _('DHCPv6 / RA'), {
		on: _('DHCPv6, prefix delegation and router advertisements of the LAN are switched on, with the RA flags and NTP servers of the General tab.'),
		off: _('DHCPv6, prefix delegation and router advertisements of the LAN are switched off and the RA flags are cleared.'),
		keep: _('DHCPv6 and router advertisements of the LAN are left as they are.') } ],
	cloudflared: [ _('Cloudflared'), {
		on: _('Enabled in its config and started.'),
		off: _('Disabled in its config and stopped.'),
		keep: _('Left as it is.') } ]
};

/* External services (not part of the base system): listed only when installed, which is
 * when their init script exists. service -> name of its init script. Anything added here
 * must also be known to 560-keepalived-scripts. */
const EXTERNAL = { cloudflared: 'cloudflared', natmap: 'natmap' };

const callRcList = rpc.declare({
	object: 'rc',
	method: 'list',
	expect: { '': {} }
});

/* state of the keepalived sync group(s), as recorded by the hotplug script 01-ubus, and
 * whether the service runs (the group state stays after a stop) */
const callKeepalivedStatus = rpc.declare({
	object: 'keepalived',
	method: 'status',
	expect: { '': {} }
});

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

const ROLES = {
	NOTIFY_MASTER: 'MASTER',
	NOTIFY_BACKUP: 'BACKUP',
	NOTIFY_FAULT: 'FAULT',
	NOTIFY_STOP: 'STOPPED'
};

function formatTime(ts) {
	const d = new Date(ts * 1000);
	const p = n => String(n).padStart(2, '0');

	return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/* What 560-keepalived-scripts follows, by the same rules as the script: global.follow
 * ("group:<name>" or "instance:<name>"; a bare name is an instance) when it names something
 * that exists; otherwise the first vrrp_sync_group that has a defined vrrp_instance as member,
 * else the vrrp_instance on br-lan, else the only one; if none of that picks one, nothing. */
function followed() {
	const instances = uci.sections('keepalived', 'vrrp_instance').filter(s => s.name);
	const known = new Set(instances.map(s => s.name));
	const groups = uci.sections('keepalived', 'vrrp_sync_group')
		.filter(s => s.name && L.toArray(s.group).some(n => known.has(n)))
		.map(s => s.name);
	const f = { type: null, names: [], groups, instances: instances.map(s => s.name) };
	const want = uci.get(CONFIG, 'global', 'follow') ?? '';
	let type = null, name = null;

	if (want.startsWith('group:') && groups.includes(want.slice(6))) {
		type = 'group'; name = want.slice(6);
	}
	else if (want.startsWith('instance:') && known.has(want.slice(9))) {
		type = 'instance'; name = want.slice(9);
	}
	else if (known.has(want)) {
		type = 'instance'; name = want;
	}
	else if (groups.length) {
		type = 'group'; name = groups[0];
	}
	else {
		const lan = instances.find(s => s.interface === 'br-lan');

		if (lan)
			{ type = 'instance'; name = lan.name; }
		else if (instances.length === 1)
			{ type = 'instance'; name = instances[0].name; }
	}

	if (name) {
		f.type = type;
		f.names = [ name ];
	}

	return f;
}

const ROLE_COLORS = { MASTER: '#2e9d4f', BACKUP: '#e08a00', FAULT: '#d6382f', STOPPED: '#888' };

/* The state of what is followed: { role, name, type, since, note }. role is MASTER, BACKUP,
 * FAULT or STOPPED once keepalived reported one; otherwise note says why there is none. */
function roleInfo(status, service, f) {
	const info = { role: null, name: null, type: f.type, since: null, note: null };

	if (f.unreadable)
		info.note = _('The keepalived configuration cannot be read');
	else if (status == null || service == null)
		info.note = _('Unknown');
	else {
		const running = Object.values(service.keepalived?.instances ?? {}).some(i => i.running);

		if (!f.instances.length)
			info.note = running
				? _('keepalived is running, but no VRRP instance is configured')
				: _('keepalived is not running, and no VRRP instance is configured');
		else if (!running)
			info.note = _('keepalived is not running');
		else if (!f.type)
			info.note = _('keepalived is running, but no instance is followed yet: choose one in Follow');
		else {
			/* 01-ubus lists every configured instance and group, with a state once it has reported one */
			const reported = (f.type === 'group' ? status.group : status.instance) ?? [];
			const e = reported.find(x => x.name === f.names[0]);

			info.name = f.names[0];
			if (!e?.status)
				info.note = _('waiting for the first state');
			else {
				info.role = ROLES[e.status] ?? e.status;
				info.since = e.event || null;
			}
		}
	}

	return info;
}

/* "MASTER (VG, since 2026-11-05 15:02:11)" */
function roleText(status, service, f) {
	const i = roleInfo(status, service, f);

	if (i.role)
		return `${i.role} (${i.name}${i.since ? ', ' + _('since') + ' ' + formatTime(i.since) : ''})`;

	return i.name ? `${i.name}: ${i.note}` : i.note;
}

/* everything the pages need; the uci files are read again, so a poll sees changes */
function loadState() {
	uci.unload([ CONFIG, 'keepalived' ]);

	return Promise.all([
		uci.load(CONFIG),
		L.resolveDefault(uci.load('keepalived'), null),
		L.resolveDefault(callRcList(), null),
		L.resolveDefault(callKeepalivedStatus(), null),
		L.resolveDefault(callServiceList('keepalived'), null)
	]).then(res => {
		/* the keepalived config is what the actions follow: without it there is nothing to do */
		const f = (res[1] != null)
			? followed()
			: { type: null, names: [], groups: [], instances: [], unreadable: true };

		return { f, rc: res[2], status: res[3], service: res[4] };
	});
}

/* the external services only when their init script exists (rc == null: not known, show all) */
function isInstalled(svc, rc) {
	return !EXTERNAL[svc] || rc == null || (EXTERNAL[svc] in rc);
}

/* the action a service gets in a state: the configured one, else the built-in default */
function actionOf(state, svc) {
	return uci.get(CONFIG, state, svc) ?? DEFAULTS[state]?.[svc];
}

/* built-in defaults of 560-keepalived-scripts, per state */
/* the order on the page: the DHCP side first (dnsmasq, DHCPv4, DHCPv6), then lease sync,
 * then the external services in alphabetical order */
const ORDER = [ 'dnsmasq', 'dhcpv4', 'dhcpv6', 'lease_sync', 'cloudflared', 'natmap' ];
const DEFAULTS = {
	master:   { dhcpv4: 'on',   dnsmasq: 'on',   natmap: 'on',  lease_sync: 'on',  dhcpv6: 'on',   cloudflared: 'off' },
	backup:   { dhcpv4: 'off',  dnsmasq: 'on',   natmap: 'off', lease_sync: 'off', dhcpv6: 'off',  cloudflared: 'on'  },
	fault:    { dhcpv4: 'keep', dnsmasq: 'keep', natmap: 'off', lease_sync: 'off', dhcpv6: 'keep', cloudflared: 'off' },
	shutdown: { dhcpv4: 'keep', dnsmasq: 'keep', natmap: 'off', lease_sync: 'keep', dhcpv6: 'keep', cloudflared: 'off' }
};


/* the role word in bold, in the colour of its state */
function roleNode(role) {
	return E('strong', { 'style': 'color:%s'.format(ROLE_COLORS[role] ?? 'inherit') }, role);
}

const ACTION_LABELS = { on: _('On'), off: _('Off'), keep: _('Keep as it is') };
const STATES = { MASTER: 'master', BACKUP: 'backup', FAULT: 'fault' };

/* what is followed, its state and whether the role actions are switched on; one row */
function roleTable(data) {
	const i = roleInfo(data.status, data.service, data.f);
	const enabled = uci.get(CONFIG, 'global', 'enabled') !== '0';
	const follows = data.f.type
		? (data.f.type === 'group' ? _('Sync group %s') : _('Instance %s')).format(data.f.names[0])
		: '-';

	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Follows')),
			E('th', { 'class': 'th' }, _('Current role')),
			E('th', { 'class': 'th' }, _('Since')),
			E('th', { 'class': 'th' }, _('Role actions'))
		]),
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, follows),
			E('td', { 'class': 'td' }, i.role ? roleNode(i.role) : (i.note ?? '-')),
			E('td', { 'class': 'td' }, i.since ? formatTime(i.since) : '-'),
			E('td', { 'class': 'td' }, enabled ? _('Enabled') : _('Disabled'))
		])
	]);
}

/* the action of every service in the current state; null when there is no such state */
function actionsTable(data) {
	const i = roleInfo(data.status, data.service, data.f);
	const state = STATES[i.role];

	if (!state)
		return null;

	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Service')),
			E('th', { 'class': 'th' }, _('Action in %s').format(i.role))
		])
	].concat(ORDER.filter(svc => DEFAULTS[state][svc] != null && isInstalled(svc, data.rc)).map(svc =>
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, SERVICES[svc][0]),
			E('td', { 'class': 'td' }, ACTION_LABELS[actionOf(state, svc)] ?? actionOf(state, svc))
		]))));
}

return baseclass.extend({
	CONFIG, SERVICES, EXTERNAL, ROLES, ROLE_COLORS, ORDER, DEFAULTS, ACTION_LABELS,
	formatTime, followed, roleInfo, roleText, loadState, isInstalled, actionOf,
	roleNode, roleTable, actionsTable
});
