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

    // -----------------------------------------------------------------------
    // Presence policy — resolved once per request and cached in-scope.
    // -----------------------------------------------------------------------
    public class PresenceTransferPolicy {
        public Boolean allowAnyDestinationQueue = true;
        public Set<Id>  assignedQueueIds         = new Set<Id>();
        public Boolean  assignedQueuesResolved    = false;
    }

    @TestVisible private static QueueAnalyticsProvider    providerOverride;
    @TestVisible private static PresenceTransferPolicy    policyOverride;

    // -----------------------------------------------------------------------
    // resolvePresenceTransferPolicy
    //   1. Find PresenceUserConfig for the running user (user-level first,
    //      then profile-level fallback).
    //   2. If OptionsIsAllowAnyDestinationQueueForTransferEnabled == false,
    //      attempt to read the specific queue list from UserConfigTransferButton
    //      WHERE PresenceUserConfigId = configId (QueueId field).
    //      This uses dynamic SOQL so the class compiles even when the fields
    //      don't exist in orgs that still use the legacy Live Chat model.
    // -----------------------------------------------------------------------
    @TestVisible
    private static PresenceTransferPolicy resolvePresenceTransferPolicy() {
        if (policyOverride != null) {
            return policyOverride;
        }

        PresenceTransferPolicy policy = new PresenceTransferPolicy();

        try {
            // Step 1 – locate the Presence Configuration for the running user.
            Id userId    = UserInfo.getUserId();
            Id profileId = UserInfo.getProfileId();
            Id configId  = null;

            List<SObject> byUser = Database.query(
                'SELECT PresenceUserConfigId FROM PresenceUserConfigUser ' +
                'WHERE UserId = :userId LIMIT 1'
            );
            if (!byUser.isEmpty()) {
                configId = (Id) byUser[0].get('PresenceUserConfigId');
            } else {
                List<SObject> byProfile = Database.query(
                    'SELECT PresenceUserConfigId FROM PresenceUserConfigProfile ' +
                    'WHERE ProfileId = :profileId LIMIT 1'
                );
                if (!byProfile.isEmpty()) {
                    configId = (Id) byProfile[0].get('PresenceUserConfigId');
                }
            }

            if (configId == null) {
                // No presence config assigned → treat as "allow any".
                return policy;
            }

            // Step 2 – read the policy flag.
            List<SObject> configs = Database.query(
                'SELECT OptionsIsAllowAnyDestinationQueueForTransferEnabled ' +
                'FROM PresenceUserConfig WHERE Id = :configId LIMIT 1'
            );
            if (configs.isEmpty()) {
                return policy;
            }

            policy.allowAnyDestinationQueue =
                (Boolean) configs[0].get('OptionsIsAllowAnyDestinationQueueForTransferEnabled');

            if (policy.allowAnyDestinationQueue) {
                return policy;
            }

            // Step 3 – specific queues: UserConfigTransferButton.PresenceUserConfigId / QueueId.
            // These fields exist in orgs with the modern Omni-Channel data model.
            // In legacy Live Chat orgs the query will throw a QueryException (no such column)
            // and we fall through to the QueueSobject fallback below.
            try {
                List<SObject> transferButtons = Database.query(
                    'SELECT QueueId FROM UserConfigTransferButton ' +
                    'WHERE PresenceUserConfigId = :configId AND QueueId != null'
                );
                for (SObject btn : transferButtons) {
                    policy.assignedQueueIds.add((Id) btn.get('QueueId'));
                }
                policy.assignedQueuesResolved = !policy.assignedQueueIds.isEmpty();
            } catch (QueryException qe) {
                // Field PresenceUserConfigId / QueueId not available in this org.
                // Fall back to showing all QueueSobject queues for the SObject type.
                policy.assignedQueuesResolved = false;
            }

        } catch (Exception ex) {
            // Omni-Channel not provisioned in this org — return open policy.
        }

        return policy;
    }

    @AuraEnabled
    public static List<TransferQueueView> getTransferQueues(String objectApiName, String searchTerm) {
        validateObjectApiName(objectApiName);

        PresenceTransferPolicy policy = resolvePresenceTransferPolicy();

        // Collect all queues enabled for this SObject type (always needed as
        // a universe set and as fallback when specific assignments are unavailable).
        Set<Id> queueIdsFromSobject = new Set<Id>();
        for (QueueSobject queueMapping : [
            SELECT QueueId
            FROM QueueSobject
            WHERE SobjectType = :objectApiName
            WITH SECURITY_ENFORCED
        ]) {
            queueIdsFromSobject.add(queueMapping.QueueId);
        }

        Set<Id> eligibleQueueIds;

        if (policy.allowAnyDestinationQueue) {
            // PresenceUserConfig allows any destination queue.
            eligibleQueueIds = queueIdsFromSobject;
        } else if (policy.assignedQueuesResolved && !policy.assignedQueueIds.isEmpty()) {
            // Modern Omni-Channel org: use the explicit assignment list.
            // Intersect with QueueSobject so we only show queues that can
            // actually receive work items of the requested SObject type.
            eligibleQueueIds = new Set<Id>();
            for (Id qId : policy.assignedQueueIds) {
                if (queueIdsFromSobject.contains(qId)) {
                    eligibleQueueIds.add(qId);
                }
            }
            // If the intersection is empty the admin may not have mapped the
            // queues to this SObject type — show all as a safe fallback.
            if (eligibleQueueIds.isEmpty()) {
                eligibleQueueIds = queueIdsFromSobject;
            }
        } else {
            // Legacy Live Chat org or no assignment data — show all.
            eligibleQueueIds = queueIdsFromSobject;
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
