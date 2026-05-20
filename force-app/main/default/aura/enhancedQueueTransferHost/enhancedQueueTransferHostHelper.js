({
    installBridge: function(component) {
        var bridge = window.enhancedQueueTransferOmniBridge || {};
        var instanceKey = component.getGlobalId();
        var self = this;

        bridge.__instances = bridge.__instances || {};
        bridge.__instances[instanceKey] = component;
        bridge.__ownerKey = instanceKey;

        // Native destination queues are not exposed by a stable public API in
        // all org variants; LWC already has Apex fallback. We return [] here.
        bridge.getTransferQueues = bridge.getTransferQueues || function() {
            return Promise.resolve([]);
        };

        bridge.transferVoiceCallToQueue = function(payload) {
            return self.transferVoiceCallNative(component, payload || {});
        };

        bridge.transferWorkToQueue = function(payload) {
            return self.transferVoiceCallNative(component, payload || {});
        };

        bridge.transferToQueue = function(payload) {
            return self.transferVoiceCallNative(component, payload || {});
        };

        bridge.transfer = function(payload) {
            return self.transferVoiceCallNative(component, payload || {});
        };

        window.enhancedQueueTransferOmniBridge = bridge;
    },

    uninstallBridge: function(component) {
        var bridge = window.enhancedQueueTransferOmniBridge;
        if (!bridge || !bridge.__instances) {
            return;
        }
        var key = component.getGlobalId();
        delete bridge.__instances[key];
        if (bridge.__ownerKey === key) {
            bridge.__ownerKey = null;
        }
    },

    transferVoiceCallNative: function(component, payload) {
        var recordId = payload.recordId;
        var queueId =
            payload.queueId ||
            payload.targetQueueId ||
            payload.destinationQueueId;

        if (!recordId || !queueId) {
            return Promise.reject(new Error('recordId e queueId são obrigatórios.'));
        }

        var omniToolkit = component.find('omniToolkit');
        var methodCandidates = [
            'transferWorkToQueue',
            'transferWork',
            'transfer',
            'transferVoiceCallToQueue'
        ];

        // 1) Preferred path: lightning:omniToolkitAPI (supports native voice stacks).
        if (omniToolkit) {
            for (var i = 0; i < methodCandidates.length; i++) {
                var methodName = methodCandidates[i];
                if (typeof omniToolkit[methodName] !== 'function') {
                    continue;
                }
                return this.invokeToolkitMethod(omniToolkit, methodName, recordId, queueId);
            }
        }

        // 2) Optional org-provided adapter hook (for provider-specific APIs).
        if (
            window.enhancedQueueTransferVoiceProvider &&
            typeof window.enhancedQueueTransferVoiceProvider.transferToQueue === 'function'
        ) {
            return Promise.resolve(
                window.enhancedQueueTransferVoiceProvider.transferToQueue({
                    recordId: recordId,
                    queueId: queueId
                })
            );
        }

        // 3) Explicitly fail: do not fake Voice transfer via OwnerId update.
        return Promise.reject(
            new Error(
                'Nenhum adaptador nativo de voz disponível (omniToolkitAPI/voiceProvider). ' +
                'Confirme que a página usa o componente Enhanced Queue Transfer Host ' +
                'em uma Console App com Omni ativo.'
            )
        );
    },

    invokeToolkitMethod: function(omniToolkit, methodName, recordId, queueId) {
        var payloadVariants = [
            {
                recordId: recordId,
                queueId: queueId,
                destinationQueueId: queueId,
                targetQueueId: queueId
            },
            {
                workId: recordId,
                queueId: queueId,
                destinationQueueId: queueId,
                targetQueueId: queueId
            },
            {
                voiceCallId: recordId,
                queueId: queueId,
                destinationQueueId: queueId,
                targetQueueId: queueId
            }
        ];

        var run = function(index) {
            if (index >= payloadVariants.length) {
                return Promise.reject(
                    new Error('Falha ao executar transferência no toolkit nativo.')
                );
            }
            return Promise.resolve(omniToolkit[methodName](payloadVariants[index])).then(
                function(result) {
                    if (result === false) {
                        throw new Error('Toolkit retornou false');
                    }
                    return result;
                }
            ).catch(function() {
                return run(index + 1);
            });
        };

        return run(0);
    }
})
