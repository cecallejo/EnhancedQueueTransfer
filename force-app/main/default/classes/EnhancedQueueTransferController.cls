public with sharing class EnhancedQueueTransferController {
    private static final Set<String> SUPPORTED_OBJECTS = new Set<String>{
        'VoiceCall',
        'MessagingSession',
        // Kept for local validation/tests where Voice objects may be unavailable.
        'Case'
    };

    public class TransferQueueView {
        @AuraEnabled public Id queueId;
        @AuraEnabled public String queueName;
        @AuraEnabled public Integer waitingCount;
        @AuraEnabled public Integer ewtMinutes;
        @AuraEnabled public Boolean canTransfer;
    }

    public class PresenceTransferPolicy {
        public Boolean allowAnyDestinationQueue = true;
        public Set<Id> configuredQueueIds = new Set<Id>();
        public Map<Id, String> configuredQueueLabels = new Map<Id, String>();
        public String configMasterLabel;
        public String keywordHint;
    }

    public class QueueMetric {
        public Integer waitingCount;
        public Integer ewtMinutes;

        public QueueMetric(Integer waitingCount, Integer ewtMinutes) {
            this.waitingCount = waitingCount;
            this.ewtMinutes = ewtMinutes;
        }
    }

    public interface QueueAnalyticsProvider {
        Map<Id, QueueMetric> getMetrics(Set<Id> queueIds);
    }

    @TestVisible
    private class LiveQueueAnalyticsProvider implements QueueAnalyticsProvider {
        public Map<Id, QueueMetric> getMetrics(Set<Id> queueIds) {
            Map<Id, QueueMetric> result = new Map<Id, QueueMetric>();
            if (queueIds == null || queueIds.isEmpty()) {
                return result;
            }

            result.putAll(resolveMessagingSessionRealtimeMetrics(queueIds));

            Map<Id, Group> queueGroups = new Map<Id, Group>([
                SELECT Id, Name
                FROM Group
                WHERE Id IN :queueIds
                AND Type = 'Queue'
                WITH SECURITY_ENFORCED
            ]);

            Set<String> queueNames = new Set<String>();
            for (Group queueGroup : queueGroups.values()) {
                queueNames.add(queueGroup.Name);
            }

            Map<String, QueueMetric> metricByQueueName = resolveMetricsByQueueName(queueNames);
            for (Id queueId : queueIds) {
                String queueName = queueGroups.get(queueId) == null ? null : queueGroups.get(queueId).Name;
                if (queueName != null && metricByQueueName.containsKey(queueName)) {
                    QueueMetric nativeMetric = metricByQueueName.get(queueName);
                    if (result.containsKey(queueId)) {
                        QueueMetric realtimeMetric = result.get(queueId);
                        // Keep waiting from realtime queue count, but source EWT from native routing stats.
                        Integer mergedWaiting = realtimeMetric == null ? null : realtimeMetric.waitingCount;
                        Integer mergedEwt = nativeMetric == null ? null : nativeMetric.ewtMinutes;
                        result.put(queueId, new QueueMetric(mergedWaiting, mergedEwt));
                    } else {
                        result.put(queueId, nativeMetric);
                    }
                }
            }

            for (Id queueId : queueIds) {
                if (!result.containsKey(queueId)) {
                    result.put(queueId, new QueueMetric(0, 0));
                }
            }
            return result;
        }

        private Map<Id, QueueMetric> resolveMessagingSessionRealtimeMetrics(Set<Id> queueIds) {
            Map<Id, Integer> waitingByQueue = new Map<Id, Integer>();

            try {
                for (SObject session : Database.query(
                    'SELECT Id, OwnerId FROM MessagingSession ' +
                    'WHERE OwnerId IN :queueIds AND Status = \'Waiting\''
                )) {
                    Id ownerId = (Id) session.get('OwnerId');
                    Integer currentCount = waitingByQueue.containsKey(ownerId)
                        ? waitingByQueue.get(ownerId)
                        : 0;
                    waitingByQueue.put(ownerId, currentCount + 1);
                }
            } catch (Exception ex) {
                // MessagingSession not available in this org.
            }

            Map<Id, QueueMetric> metrics = new Map<Id, QueueMetric>();
            for (Id queueId : queueIds) {
                Integer waitingCount = waitingByQueue.containsKey(queueId) ? waitingByQueue.get(queueId) : 0;
                metrics.put(queueId, new QueueMetric(waitingCount, null));
            }
            return metrics;
        }

    }

    @TestVisible
    private class MockQueueAnalyticsProvider implements QueueAnalyticsProvider {
        public Map<Id, QueueMetric> getMetrics(Set<Id> queueIds) {
            Map<Id, QueueMetric> result = new Map<Id, QueueMetric>();
            for (Id queueId : queueIds) {
                Integer seed = Math.abs(String.valueOf(queueId).hashCode());
                Integer waiting = Math.mod(seed, 15);
                Integer ewt = Math.mod(seed, 8) + 1;
                result.put(queueId, new QueueMetric(waiting, ewt));
            }
            return result;
        }
    }

    private class EmptyQueueAnalyticsProvider implements QueueAnalyticsProvider {
        public Map<Id, QueueMetric> getMetrics(Set<Id> queueIds) {
            return new Map<Id, QueueMetric>();
        }
    }

    @TestVisible private static QueueAnalyticsProvider providerOverride;
    @TestVisible private static PresenceTransferPolicy presencePolicyOverride;

    @AuraEnabled
    public static List<TransferQueueView> getTransferQueues(String objectApiName, String searchTerm) {
        validateObjectApiName(objectApiName);

        PresenceTransferPolicy transferPolicy = resolvePresenceTransferPolicy(UserInfo.getUserId());

        Set<Id> queueIdsFromSobject = new Set<Id>();
        for (QueueSobject queueMapping : [
            SELECT QueueId
            FROM QueueSobject
            WHERE SobjectType = :objectApiName
            WITH SECURITY_ENFORCED
        ]) {
            queueIdsFromSobject.add(queueMapping.QueueId);
        }

        Set<Id> eligibleQueueIds = new Set<Id>();
        if (!transferPolicy.allowAnyDestinationQueue && !transferPolicy.configuredQueueIds.isEmpty()) {
            // Presence Config has specific queues configured: they are the source of truth.
            // QueueSobject mapping is informational only and should not override admin intent.
            eligibleQueueIds.addAll(transferPolicy.configuredQueueIds);
        } else if (!queueIdsFromSobject.isEmpty()) {
            // No restriction: show all queues mapped to this SObject type.
            eligibleQueueIds.addAll(queueIdsFromSobject);
        } else {
            // Last-resort: no QueueSobject mapping, fall back to configured queues.
            eligibleQueueIds.addAll(transferPolicy.configuredQueueIds);
        }

        if (eligibleQueueIds.isEmpty()) {
            return new List<TransferQueueView>();
        }

        String normalizedSearchTerm = searchTerm == null ? null : searchTerm.trim();
        Map<Id, Group> queuesById = queryQueuesBySearch(eligibleQueueIds, normalizedSearchTerm);

        Map<Id, QueueMetric> liveMetrics = resolveLiveProvider().getMetrics(eligibleQueueIds);
        Map<Id, QueueMetric> fallbackMetrics = resolveFallbackProvider().getMetrics(eligibleQueueIds);

        List<TransferQueueView> queueViews = new List<TransferQueueView>();
        for (Id queueId : eligibleQueueIds) {
            Group queueGroup = queuesById.get(queueId);
            if (queueGroup == null) {
                continue;
            }
            if (shouldFilterOutByKeywordHint(objectApiName, transferPolicy, queueGroup.Name)) {
                continue;
            }

            QueueMetric metric = liveMetrics.get(queueId);
            if (metric == null) {
                metric = fallbackMetrics.get(queueId);
            }

            TransferQueueView row = new TransferQueueView();
            row.queueId = queueId;
            row.queueName = queueGroup.Name;
            row.waitingCount = metric == null ? null : metric.waitingCount;
            row.ewtMinutes = metric == null ? null : metric.ewtMinutes;
            row.canTransfer = true;
            queueViews.add(row);
        }

        return queueViews;
    }

    @AuraEnabled
    public static List<TransferQueueView> getQueueMetrics(List<Id> queueIds) {
        if (queueIds == null || queueIds.isEmpty()) {
            return new List<TransferQueueView>();
        }

        Set<Id> uniqueQueueIds = new Set<Id>(queueIds);
        Map<Id, Group> queuesById = new Map<Id, Group>([
            SELECT Id, Name
            FROM Group
            WHERE Id IN :uniqueQueueIds
            AND Type = 'Queue'
            WITH SECURITY_ENFORCED
        ]);

        Map<Id, QueueMetric> liveMetrics = resolveLiveProvider().getMetrics(uniqueQueueIds);
        Map<Id, QueueMetric> fallbackMetrics = resolveFallbackProvider().getMetrics(uniqueQueueIds);

        List<TransferQueueView> metricRows = new List<TransferQueueView>();
        for (Id queueId : uniqueQueueIds) {
            Group queueGroup = queuesById.get(queueId);
            if (queueGroup == null) {
                continue;
            }

            QueueMetric metric = liveMetrics.get(queueId);
            if (metric == null) {
                metric = fallbackMetrics.get(queueId);
            }

            TransferQueueView row = new TransferQueueView();
            row.queueId = queueId;
            row.queueName = queueGroup.Name;
            row.waitingCount = metric == null ? null : metric.waitingCount;
            row.ewtMinutes = metric == null ? null : metric.ewtMinutes;
            row.canTransfer = true;
            metricRows.add(row);
        }
        return metricRows;
    }

    @AuraEnabled
    public static List<TransferQueueView> getQueueMetricsByNames(List<String> queueNames) {
        List<TransferQueueView> rows = new List<TransferQueueView>();
        if (queueNames == null || queueNames.isEmpty()) {
            return rows;
        }

        Set<String> uniqueNames = new Set<String>();
        for (String queueName : queueNames) {
            if (!String.isBlank(queueName)) {
                uniqueNames.add(queueName.trim());
            }
        }
        if (uniqueNames.isEmpty()) {
            return rows;
        }

        Map<String, QueueMetric> metricByName = resolveMetricsByQueueName(uniqueNames);
        for (String queueName : uniqueNames) {
            QueueMetric metric = metricByName.get(queueName);
            TransferQueueView row = new TransferQueueView();
            row.queueName = queueName;
            row.waitingCount = metric == null ? null : metric.waitingCount;
            row.ewtMinutes = metric == null ? null : metric.ewtMinutes;
            row.canTransfer = true;
            rows.add(row);
        }
        return rows;
    }

    @AuraEnabled
    public static void transferRecordToQueue(Id recordId, Id queueId) {
        if (recordId == null || queueId == null) {
            throw new AuraHandledException('recordId and queueId are required.');
        }

        String objectApiName = recordId.getSObjectType().getDescribe().getName();
        validateObjectApiName(objectApiName);

        List<SObject> candidateRecords = Database.query(
            'SELECT Id, OwnerId FROM ' + objectApiName + ' WHERE Id = :recordId WITH SECURITY_ENFORCED LIMIT 1'
        );
        if (candidateRecords.isEmpty()) {
            throw new AuraHandledException('Record not found.');
        }

        SObject recordToTransfer = candidateRecords[0];
        recordToTransfer.put('OwnerId', queueId);

        SObjectAccessDecision accessDecision = Security.stripInaccessible(
            AccessType.UPDATABLE,
            new List<SObject>{ recordToTransfer }
        );
        List<SObject> sanitized = accessDecision.getRecords();
        if (sanitized.isEmpty()) {
            throw new AuraHandledException('Insufficient access to transfer this record.');
        }

        update sanitized;
    }

    @AuraEnabled
    public static Boolean isTransferAllowed(Id recordId, String objectApiName) {
        if (recordId == null || String.isBlank(objectApiName)) {
            return false;
        }
        validateObjectApiName(objectApiName);

        if (objectApiName != 'MessagingSession') {
            return true;
        }

        try {
            List<SObject> sessions = Database.query(
                'SELECT Id, Status FROM MessagingSession WHERE Id = :recordId LIMIT 1'
            );
            if (sessions.isEmpty()) {
                return false;
            }
            return (String) sessions[0].get('Status') == 'Active';
        } catch (Exception ex) {
            return true;
        }
    }

    private static Map<Id, Group> queryQueuesBySearch(Set<Id> queueIds, String searchTerm) {
        if (String.isBlank(searchTerm)) {
            return new Map<Id, Group>([
                SELECT Id, Name
                FROM Group
                WHERE Id IN :queueIds
                AND Type = 'Queue'
                WITH SECURITY_ENFORCED
                ORDER BY Name
                LIMIT 200
            ]);
        }

        String likeTerm = '%' + searchTerm + '%';
        return new Map<Id, Group>([
            SELECT Id, Name
            FROM Group
            WHERE Id IN :queueIds
            AND Type = 'Queue'
            AND Name LIKE :likeTerm
            WITH SECURITY_ENFORCED
            ORDER BY Name
            LIMIT 200
        ]);
    }

    // All Omni-Channel object queries use dynamic SOQL so the package compiles
    // in any org/scratch org regardless of which Service Cloud features are provisioned.
    private static PresenceTransferPolicy resolvePresenceTransferPolicy(Id userId) {
        if (Test.isRunningTest() && presencePolicyOverride != null) {
            return presencePolicyOverride;
        }

        PresenceTransferPolicy policy = new PresenceTransferPolicy();

        try {
            List<SObject> userMappings = Database.query(
                'SELECT PresenceUserConfigId FROM PresenceUserConfigUser ' +
                'WHERE UserId = :userId LIMIT 1'
            );
            if (userMappings.isEmpty()) {
                return policy;
            }

            Id configId = (Id) userMappings[0].get('PresenceUserConfigId');
            List<SObject> configs = Database.query(
                'SELECT Id, MasterLabel, OptionsIsAllowAnyDestinationQueueForTransferEnabled ' +
                'FROM PresenceUserConfig WHERE Id = :configId LIMIT 1'
            );
            if (configs.isEmpty()) {
                return policy;
            }

            SObject config = configs[0];
            policy.allowAnyDestinationQueue = (Boolean) config.get('OptionsIsAllowAnyDestinationQueueForTransferEnabled');
            policy.configMasterLabel = (String) config.get('MasterLabel');
            policy.keywordHint = deriveKeywordHint(policy.configMasterLabel);
            if (policy.allowAnyDestinationQueue) {
                return policy;
            }

            Set<Id> transferButtonIds = new Set<Id>();
            for (SObject buttonConfig : Database.query(
                'SELECT LiveChatButtonId FROM UserConfigTransferButton ' +
                'WHERE PresenceUserConfigId = :configId AND LiveChatButtonId != null'
            )) {
                transferButtonIds.add((Id) buttonConfig.get('LiveChatButtonId'));
            }
            if (transferButtonIds.isEmpty()) {
                return policy;
            }

            for (SObject button : Database.query(
                'SELECT QueueId, MasterLabel FROM LiveChatButton ' +
                'WHERE Id IN :transferButtonIds AND QueueId != null'
            )) {
                Id queueId = (Id) button.get('QueueId');
                String masterLabel = (String) button.get('MasterLabel');
                policy.configuredQueueIds.add(queueId);
                if (!String.isBlank(masterLabel)) {
                    policy.configuredQueueLabels.put(queueId, masterLabel);
                }
            }
        } catch (Exception ex) {
            // Feature not available in this org — return open policy.
        }

        return policy;
    }

    private static void validateObjectApiName(String objectApiName) {
        if (String.isBlank(objectApiName) || !SUPPORTED_OBJECTS.contains(objectApiName)) {
            throw new AuraHandledException('Object is not supported for queue transfer.');
        }
    }

    private static QueueAnalyticsProvider resolveLiveProvider() {
        if (providerOverride != null) {
            return providerOverride;
        }
        return new LiveQueueAnalyticsProvider();
    }

    private static QueueAnalyticsProvider resolveFallbackProvider() {
        if (Test.isRunningTest()) {
            return new MockQueueAnalyticsProvider();
        }
        // In runtime, never fabricate queue metrics.
        return new EmptyQueueAnalyticsProvider();
    }

    private static String deriveKeywordHint(String masterLabel) {
        if (String.isBlank(masterLabel) || !masterLabel.contains('-')) {
            return null;
        }
        List<String> parts = masterLabel.split('-');
        if (parts.isEmpty()) {
            return null;
        }
        String candidate = parts[parts.size() - 1];
        return String.isBlank(candidate) ? null : candidate.trim().toLowerCase();
    }

    private static Boolean shouldFilterOutByKeywordHint(
        String objectApiName,
        PresenceTransferPolicy policy,
        String queueName
    ) {
        if (objectApiName != 'MessagingSession') {
            return false;
        }
        if (String.isBlank(policy.keywordHint) || String.isBlank(queueName)) {
            return false;
        }
        return !queueName.toLowerCase().contains(policy.keywordHint);
    }

    private static Map<String, QueueMetric> resolveMetricsByQueueName(Set<String> queueNames) {
        Map<String, QueueMetric> metricByName = new Map<String, QueueMetric>();
        if (queueNames == null || queueNames.isEmpty()) {
            return metricByName;
        }

        // Dynamic SOQL avoids compile-time dependency on SDO_Service_Queue_Stat__c,
        // which is a demo-org custom object that may not exist in all target orgs.
        try {
            String soql =
                'SELECT Queue_Name__c, Calls_Queued__c, Avg_Queue_Time__c, LastModifiedDate' +
                ' FROM SDO_Service_Queue_Stat__c' +
                ' WHERE Queue_Name__c IN :queueNames' +
                ' ORDER BY LastModifiedDate DESC';
            for (SObject stat : Database.query(soql)) {
                String queueName = (String) stat.get('Queue_Name__c');
                if (metricByName.containsKey(queueName)) {
                    continue;
                }
                Decimal callsQueued = (Decimal) stat.get('Calls_Queued__c');
                Decimal avgQueueTime = (Decimal) stat.get('Avg_Queue_Time__c');
                Integer waitingCount = callsQueued == null ? null : Integer.valueOf(callsQueued);
                Integer ewtMinutes = avgQueueTime == null ? null : Integer.valueOf(Math.round(avgQueueTime));
                metricByName.put(queueName, new QueueMetric(waitingCount, ewtMinutes));
            }
        } catch (Exception ex) {
            return new Map<String, QueueMetric>();
        }

        return metricByName;
    }

}
