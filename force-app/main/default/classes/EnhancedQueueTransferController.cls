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

            for (MessagingSession session : [
                SELECT Id, OwnerId, CreatedDate
                FROM MessagingSession
                WHERE OwnerId IN :queueIds
                AND Status = 'Waiting'
                WITH SECURITY_ENFORCED
            ]) {
                Integer currentCount = waitingByQueue.containsKey(session.OwnerId)
                    ? waitingByQueue.get(session.OwnerId)
                    : 0;
                waitingByQueue.put(session.OwnerId, currentCount + 1);
            }

            Map<Id, QueueMetric> metrics = new Map<Id, QueueMetric>();
            for (Id queueId : queueIds) {
                Integer waitingCount = waitingByQueue.containsKey(queueId) ? waitingByQueue.get(queueId) : 0;
                Integer ewtMinutes = null;
                metrics.put(queueId, new QueueMetric(waitingCount, ewtMinutes));
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

    @AuraEnabled(cacheable=true)
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
            Set<Id> restrictedIntersection = new Set<Id>(queueIdsFromSobject);
            restrictedIntersection.retainAll(transferPolicy.configuredQueueIds);
            // Prefer strict intersection when available; otherwise keep object-mapped queues.
            if (!restrictedIntersection.isEmpty()) {
                eligibleQueueIds.addAll(restrictedIntersection);
            } else {
                eligibleQueueIds.addAll(queueIdsFromSobject);
            }
        } else if (!queueIdsFromSobject.isEmpty()) {
            eligibleQueueIds.addAll(queueIdsFromSobject);
        } else {
            // Last-resort fallback for orgs where queue/object mapping is not maintained.
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

    @AuraEnabled(cacheable=true)
    public static Boolean isTransferAllowed(Id recordId, String objectApiName) {
        if (recordId == null || String.isBlank(objectApiName)) {
            return false;
        }
        validateObjectApiName(objectApiName);

        if (objectApiName != 'MessagingSession') {
            return true;
        }

        List<MessagingSession> sessions = [
            SELECT Id, Status
            FROM MessagingSession
            WHERE Id = :recordId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (sessions.isEmpty()) {
            return false;
        }
        return sessions[0].Status == 'Active';
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

    private static PresenceTransferPolicy resolvePresenceTransferPolicy(Id userId) {
        if (Test.isRunningTest() && presencePolicyOverride != null) {
            return presencePolicyOverride;
        }

        PresenceTransferPolicy policy = new PresenceTransferPolicy();

        List<PresenceUserConfigUser> userMappings = [
            SELECT PresenceUserConfigId
            FROM PresenceUserConfigUser
            WHERE UserId = :userId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (userMappings.isEmpty()) {
            return policy;
        }

        PresenceUserConfig config = [
            SELECT Id, MasterLabel, OptionsIsAllowAnyDestinationQueueForTransferEnabled
            FROM PresenceUserConfig
            WHERE Id = :userMappings[0].PresenceUserConfigId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        policy.allowAnyDestinationQueue = config.OptionsIsAllowAnyDestinationQueueForTransferEnabled;
        policy.configMasterLabel = config.MasterLabel;
        policy.keywordHint = deriveKeywordHint(config.MasterLabel);
        if (policy.allowAnyDestinationQueue) {
            return policy;
        }

        Set<Id> transferButtonIds = new Set<Id>();
        for (UserConfigTransferButton buttonConfig : [
            SELECT LiveChatButtonId
            FROM UserConfigTransferButton
            WHERE LiveChatButtonId != null
            WITH SECURITY_ENFORCED
        ]) {
            transferButtonIds.add(buttonConfig.LiveChatButtonId);
        }
        if (transferButtonIds.isEmpty()) {
            return policy;
        }

        for (LiveChatButton button : [
            SELECT QueueId, MasterLabel
            FROM LiveChatButton
            WHERE Id IN :transferButtonIds
            AND QueueId != null
            WITH SECURITY_ENFORCED
        ]) {
            policy.configuredQueueIds.add(button.QueueId);
            if (!String.isBlank(button.MasterLabel)) {
                policy.configuredQueueLabels.put(button.QueueId, button.MasterLabel);
            }
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

        try {
            for (SDO_Service_Queue_Stat__c stat : [
                SELECT Queue_Name__c, Calls_Queued__c, Avg_Queue_Time__c, LastModifiedDate
                FROM SDO_Service_Queue_Stat__c
                WHERE Queue_Name__c IN :queueNames
                WITH SECURITY_ENFORCED
                ORDER BY LastModifiedDate DESC
            ]) {
                if (metricByName.containsKey(stat.Queue_Name__c)) {
                    continue;
                }
                Integer waitingCount = stat.Calls_Queued__c == null ? null : Integer.valueOf(stat.Calls_Queued__c);
                Integer ewtMinutes = stat.Avg_Queue_Time__c == null ? null : Integer.valueOf(Math.round(stat.Avg_Queue_Time__c));
                metricByName.put(stat.Queue_Name__c, new QueueMetric(waitingCount, ewtMinutes));
            }
        } catch (Exception ex) {
            return new Map<String, QueueMetric>();
        }

        return metricByName;
    }

}
