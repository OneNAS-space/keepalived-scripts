/* Role Actions: settings of keepalived-scripts (/etc/config/keepalived_scripts).
 * The hotplug script 560-keepalived-scripts reads them at every keepalived state change;
 * the built-in defaults below are the ones it falls back to when an option is missing. */
'use strict';
'require view';
'require form';
'require ui';
'require uci';
'require rpc';

const CONFIG = 'keepalived_scripts';
const SECTIONS = [ 'global', 'master', 'backup', 'fault', 'shutdown', 'sync' ];

/* service -> [ title, help ] */
const SERVICES = {
	dhcpv4: [ _('DHCPv4'),
		_('DHCPv4 server of the LAN. On: gateway and DNS are handed out as the LAN VIP.') ],
	dnsmasq: [ _('Dnsmasq'),
		_('Off stops it: the router itself then has no resolver either and needs another upstream DNS.') ],
	natmap: [ _('Natmap'),
		_('Skipped when it is not installed.') ],
	lease_sync: [ _('Lease sync'),
		_('On: push the leases and the DHCP config of this node to the peer (see the Lease sync tab).') ],
	dhcpv6: [ _('DHCPv6 / RA'),
		_('DHCPv6 and router advertisements of the LAN.') ],
	cloudflared: [ _('Cloudflared'),
		_('Skipped when it is not installed.') ]
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

/* "MASTER (VG, since 2026-11-05 15:02:11)" */
function roleText(status, service, f) {
	if (f.unreadable)
		return _('The keepalived configuration cannot be read');

	if (status == null || service == null)
		return _('Unknown');

	const running = Object.values(service.keepalived?.instances ?? {}).some(i => i.running);

	if (!f.instances.length)
		return running
			? _('keepalived is running, but no VRRP instance is configured')
			: _('keepalived is not running, and no VRRP instance is configured');

	if (!running)
		return _('keepalived is not running');

	if (!f.type)
		return _('keepalived is running, but no instance is followed yet: choose one in Follow');

	/* 01-ubus lists every configured instance and group, with a state once it has reported one */
	const reported = (f.type === 'group' ? status.group : status.instance) ?? [];

	return f.names.map(name => {
		const e = reported.find(x => x.name === name);

		if (!e?.status)
			return `${name}: ${_('waiting for the first state')}`;

		const role = ROLES[e.status] ?? e.status;
		return `${role} (${name}${e.event ? ', ' + _('since') + ' ' + formatTime(e.event) : ''})`;
	}).join(', ');
}

/* init scripts of this router; null when they could not be read (then nothing is hidden) */
let initScripts = null;

function isInstalled(svc) {
	return !EXTERNAL[svc] || initScripts == null || (EXTERNAL[svc] in initScripts);
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

const RA_FLAGS = [ 'managed-config', 'other-config', 'home-agent' ];
const NTP_SERVERS = [
	'0.openwrt.pool.ntp.org', '1.openwrt.pool.ntp.org',
	'2.openwrt.pool.ntp.org', '3.openwrt.pool.ntp.org'
];

/* after: { <service>: function(section) } adds more options right after that service */
function addActions(s, state, help, after) {
	for (const svc of ORDER) {
		const def = DEFAULTS[state][svc];
		if (def == null || !isInstalled(svc))
			continue;

		const o = s.option(form.ListValue, svc, SERVICES[svc][0],
			(help && help[svc]) || SERVICES[svc][1]);
		o.value('on', _('On'));
		o.value('off', _('Off'));
		o.value('keep', _('Keep as it is'));
		o.default = def;
		o.rmempty = false;

		if (after && after[svc])
			after[svc](s);
	}
}

return view.extend({
	load() {
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

			/* a section that was trimmed from the file is created (not saved until Save & Apply) */
			const needed = (f.unreadable || !f.instances.length) ? [ 'global' ] : SECTIONS;
			for (const name of needed)
				if (!uci.get(CONFIG, name))
					uci.add(CONFIG, 'keepalived_scripts', name);

			return { f, rc: res[2], status: res[3], service: res[4] };
		});
	},

	/* wrap the sections of the rendered map into tabs */
	tabs(mapEl, names) {
		const panes = mapEl.querySelectorAll(':scope > .cbi-section');

		if (panes.length !== names.length)
			return mapEl;

		const group = E('div', { 'class': 'cbi-map-tabbed' });
		mapEl.insertBefore(group, panes[0]);

		panes.forEach((pane, i) => {
			const h = pane.querySelector(':scope > h3');
			pane.setAttribute('data-tab', names[i]);
			pane.setAttribute('data-tab-title', h ? h.textContent : names[i]);
			if (h)
				h.remove();
			group.appendChild(pane);
		});

		ui.tabs.initTabGroup(group.childNodes);
		return mapEl;
	},

	render(data) {
		const f = data.f;
		let m, s, o;

		initScripts = data.rc;

		/* no instance (or no keepalived config): only the state; the actions cannot be enabled */
		if (f.unreadable || !f.instances.length) {
			m = new form.Map(CONFIG, _('Role Actions'),
				f.unreadable
					? _('The keepalived configuration cannot be read, so the role actions cannot work here.')
					: _('The role actions follow the state of a VRRP sync group or of a VRRP instance. This router has no VRRP instance, so there is nothing to follow and nothing to configure.'));

			s = m.section(form.NamedSection, 'global', 'keepalived_scripts', _('General'));
			s.addremove = false;

			o = s.option(form.DummyValue, 'role', _('Current role'));
			o.cfgvalue = function() {
				return roleText(data.status, data.service, f);
			};

			/* never written: the script does nothing without an instance, whatever is stored */
			o = s.option(form.DummyValue, 'enabled', _('Enabled'),
				_('Not available: there is nothing to follow, so the role actions cannot be switched on.'));
			o.cfgvalue = function() {
				return _('Off');
			};

			return m.render().then(mapEl => this.tabs(mapEl, [ 'global' ]));
		}

		m = new form.Map(CONFIG, _('Role Actions'),
			_('What the router does when keepalived changes state: one action per service for each state of the VRRP sync group or instance it follows. Every action is On, Off, or Keep as it is (the service is left alone). The script 560-keepalived-scripts reads these settings at every state change, so they apply at the next one. The one it follows is chosen in Follow. An option that is not set falls back to the value shown. Services that are not installed are not listed.'));

		/* ---- general ---- */
		s = m.section(form.NamedSection, 'global', 'keepalived_scripts', _('General'));
		s.addremove = false;

		/* shown only, never written */
		o = s.option(form.DummyValue, 'role', _('Current role'),
			_('The state of the followed sync group or instance as of loading this page.'));
		o.cfgvalue = function() {
			return roleText(data.status, data.service, f);
		};

		/* the role actions follow one sync group or one instance; the user picks which */
		o = s.option(form.ListValue, 'follow', _('Follow'),
			_('The VRRP sync group or instance whose state the role actions follow. Automatic: the first sync group; without one, the instance on br-lan, or the only instance.'));
		o.value('', _('Automatic'));
		for (const name of f.groups)
			o.value('group:' + name, _('Sync group %s').format(name));
		for (const name of f.instances)
			o.value('instance:' + name, _('Instance %s').format(name));
		o.default = '';
		o.optional = true;
		o.cfgvalue = function(section_id) {
			const v = uci.get(CONFIG, section_id, 'follow') ?? '';

			return (v && !v.includes(':')) ? 'instance:' + v : v;
		};

		o = s.option(form.Flag, 'enabled', _('Enabled'),
			_('Off: the script does nothing at all, whatever the other tabs say.'));
		o.enabled = '1';
		o.disabled = '0';
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'settle_delay', _('Settle delay'),
			_('Seconds to wait after keepalived started before the first BACKUP is acted on: keepalived always starts as BACKUP and may become MASTER within seconds.'));
		o.datatype = 'and(uinteger, max(600))';
		o.default = '5';
		o.placeholder = '5';
		o.rmempty = false;

		o = s.option(form.DynamicList, 'ra_flags', _('RA flags'),
			_('Router advertisement flags of the LAN while DHCPv6 is on (MASTER). Empty: the default list.'));
		for (const flag of RA_FLAGS)
			o.value(flag);
		o.default = RA_FLAGS;

		o = s.option(form.DynamicList, 'ntp', _('NTP servers'),
			_('NTP servers handed out by the LAN while DHCPv6 is on (MASTER). Empty: the default list.'));
		o.datatype = 'host';
		o.default = NTP_SERVERS;

		/* ---- the states ---- */
		s = m.section(form.NamedSection, 'master', 'keepalived_scripts', _('MASTER'),
			_('This node became the active router.'));
		s.addremove = false;

		addActions(s, 'master');

		/* listed last like the options of the other tabs, but done before every action above */
		o = s.option(form.Flag, 'pull_leases', _('Take over the leases'),
			_('Fetch the DHCP leases of the peer (it was MASTER until now) before any action of this tab is carried out.'));
		o.enabled = 'on';
		o.disabled = 'off';
		o.default = 'on';
		o.rmempty = false;

		o = s.option(form.Flag, 'pull_dhcp', _('Take over the DHCP config'),
			_('Fetch /etc/config/dhcp of the peer (hosts, tags, options) before any action of this tab is carried out, right after the leases. Only the entries the role scripts set on each node stay as they are.'));
		o.enabled = 'on';
		o.disabled = 'off';
		o.default = 'on';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'backup', 'keepalived_scripts', _('BACKUP'),
			_('This node is the standby.'));
		s.addremove = false;
		addActions(s, 'backup', {
			dnsmasq: _('On keeps dnsmasq running for DNS. Off stops it, so the router itself has no resolver either and needs another upstream DNS; it also needs the keepalived-sync patch that stops 551-dnsmasq from touching dnsmasq, otherwise both fight over it.')
		});

		s = m.section(form.NamedSection, 'fault', 'keepalived_scripts', _('FAULT'),
			_('keepalived reports a fault on this node. Keeping DHCP as it is avoids interrupting clients that already have a lease.'));
		s.addremove = false;
		addActions(s, 'fault');

		s = m.section(form.NamedSection, 'shutdown', 'keepalived_scripts', _('SHUTDOWN'),
			_('keepalived stops or the router shuts down.'));
		s.addremove = false;
		addActions(s, 'shutdown', null, {
			lease_sync: function(sect) {
				const opt = sect.option(form.Flag, 'clear_ra_flags', _('Clear RA flags and NTP'),
					_('Also remove the RA flags and NTP servers from the LAN, which the MASTER state had set.'));
				opt.enabled = '1';
				opt.disabled = '0';
				opt.default = '1';
				opt.rmempty = false;
			}
		});

		/* ---- lease sync ---- */
		s = m.section(form.NamedSection, 'sync', 'keepalived_scripts', _('Lease sync'),
			_('The lease_sync service mirrors the leases and /etc/config/dhcp of the MASTER to its peer.'));
		s.addremove = false;

		/* Switched by the Lease sync actions of the states. Shown as text, never written by the page:
		 * a copy of the page that was loaded before a state change must not switch the service back. */
		o = s.option(form.DummyValue, 'enable', _('Running'),
			_('Switched by the Lease sync actions of the states (on in MASTER, off in BACKUP and FAULT by default), not a setting to change by hand.'));
		o.cfgvalue = function(section_id) {
			return uci.get(CONFIG, section_id, 'enable') == '1' ? _('On') : _('Off');
		};

		o = s.option(form.Flag, 'sync_dhcp', _('Sync the DHCP config'),
			_('Mirror /etc/config/dhcp (hosts, tags, dnsmasq options, ...) as well as the leases.'));
		o.enabled = '1';
		o.disabled = '0';
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'peer_ip', _('Peer address'),
			_('Empty: the unicast peer of the br-lan VRRP instance.'));
		o.datatype = 'ipaddr("nomask")';
		o.optional = true;
		o.placeholder = _('automatic');

		o = s.option(form.Value, 'ssh_key', _('SSH key'),
			_('Private key used to log in to the peer.'));
		o.default = '/root/.ssh/id_dropbear';
		o.placeholder = '/root/.ssh/id_dropbear';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return /^\/\S+$/.test(value) || _('Expecting an absolute path without spaces');
		};

		o = s.option(form.Value, 'interval', _('Re-check interval'),
			_('Seconds between periodic checks that the peer still matches.'));
		o.datatype = 'and(uinteger, min(5))';
		o.default = '3600';
		o.placeholder = '3600';
		o.rmempty = false;

		o = s.option(form.Value, 'retry_interval', _('Retry interval'),
			_('Seconds between retries after a failure.'));
		o.datatype = 'and(uinteger, min(5))';
		o.default = '30';
		o.placeholder = '30';
		o.rmempty = false;

		o = s.option(form.DynamicList, 'keep_local', _('More options kept as they are'),
			_('Options of /etc/config/dhcp that stay as each node has them, written as section.option, for example lan.leasetime. The role switches of the LAN section are built in.'));
		o.placeholder = 'lan.leasetime';
		o.validate = function(section_id, value) {
			if (value === '')
				return true;
			return /^[A-Za-z0-9_-]+\.[A-Za-z0-9_]+(~\S+)?$/.test(value) ||
				_('Expecting section.option, for example lan.leasetime');
		};

		/* one tab per section: the section titles become the tab titles */
		return m.render().then(mapEl => this.tabs(mapEl, SECTIONS));
	}
});
