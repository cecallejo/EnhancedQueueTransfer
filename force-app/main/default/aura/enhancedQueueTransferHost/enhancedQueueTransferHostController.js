({
    doInit: function(component, event, helper) {
        helper.installBridge(component);
    },

    doDestroy: function(component, event, helper) {
        helper.uninstallBridge(component);
    }
})
