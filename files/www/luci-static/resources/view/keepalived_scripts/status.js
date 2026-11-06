/* Status > VRRP > Role Actions: what the role actions (keepalived-scripts) are doing now.
 * The settings are in Services > VRRP > Role Actions. */
'use strict';
'require view';
'require dom';
'require poll';
'require uci';
'require keepalived_scripts.common as ks';

return view.extend({
	load() {
		return ks.loadState();
	},

	/* the two sections, filled from the loaded state */
	fill(data, roleBox, actionsBox) {
		const f = data.f;

		if (f.unreadable || !f.instances.length) {
			dom.content(roleBox, E('em', ks.roleText(data.status, data.service, f)));
			dom.content(actionsBox, null);
			actionsBox.style.display = 'none';
			return;
		}

		dom.content(roleBox, ks.roleTable(data));

		const table = ks.actionsTable(data);
		const enabled = uci.get(ks.CONFIG, 'global', 'enabled') !== '0';

		actionsBox.style.display = '';
		dom.content(actionsBox, [
			E('h3', _('Actions in effect')),
			!enabled
				? E('em', _('The role actions are switched off: nothing is done when the state changes.'))
				: table ?? E('em', _('No role is active right now, so no action applies.'))
		]);
	},

	render(data) {
		const roleBox = E('div', { 'class': 'cbi-section-node' });
		const actionsBox = E('div', { 'class': 'cbi-section' });

		this.fill(data, roleBox, actionsBox);

		poll.add(() => ks.loadState().then(d => this.fill(d, roleBox, actionsBox)));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', _('VRRP')),
			E('div', { 'class': 'cbi-map-descr' },
				_('What the role actions do on this device: the state they follow and the action each service gets in it. The settings are in Services > VRRP > Role Actions.')),
			E('div', { 'class': 'cbi-section' }, [ E('h3', _('Current role')), roleBox ]),
			actionsBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
