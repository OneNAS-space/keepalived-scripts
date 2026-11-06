/* Status overview card: the state the role actions (keepalived-scripts) follow.
 * Shown below "Keepalived Instances"; the overview reloads it by itself. */
'use strict';
'require baseclass';
'require keepalived_scripts.common as ks';

return baseclass.extend({
	title: _('VRRP Role Actions'),

	load() {
		return ks.loadState();
	},

	render(data) {
		/* nothing to follow, nothing to show */
		if (!data || data.f.unreadable || !data.f.instances.length)
			return null;

		return ks.roleTable(data);
	}
});
