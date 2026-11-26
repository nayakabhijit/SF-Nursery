({
    init: function (component) {
        var state = (component.get('v.pageReference') || {}).state || {};
        var plantId = null;

        // Related list "New": defaultFieldValues=Plant__c=a01...
        if (state.defaultFieldValues) {
            var match = /(?:^|,)Plant__c=([^,]+)/.exec(decodeURIComponent(state.defaultFieldValues));
            if (match) {
                plantId = match[1];
            }
        }

        // Older form: inContextOfRef=1.<base64 JSON page reference of the parent record>
        if (!plantId && state.inContextOfRef) {
            try {
                var ref = state.inContextOfRef;
                if (ref.indexOf('1.') === 0) {
                    ref = ref.substring(2);
                }
                var ctx = JSON.parse(window.atob(ref));
                if (ctx.attributes && ctx.attributes.objectApiName === 'Plant__c') {
                    plantId = ctx.attributes.recordId;
                }
            } catch (e) {
                // not a usable context; leave the plant empty
            }
        }

        // Remount the LWC so a reused override starts with a clean form.
        component.set('v.show', false);
        component.set('v.plantId', plantId);
        window.setTimeout(
            $A.getCallback(function () {
                if (component.isValid()) {
                    component.set('v.show', true);
                }
            }),
            0
        );
    }
});
