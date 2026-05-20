public with sharing class EnhancedQueueTransferController {
    private static final Set<String> SUPPORTED_OBJECTS = new Set<String>{
        'VoiceCall',
        'MessagingSession',
        // Kept for local validation/tests where Voice objects may be unavailable.
        'Case'
    };

    // Items still pending after 24h are treated as stale/abandoned and ignored
    // (they would otherwise inflate EWT with leftover test/debug data).
    private static final Integer STALE_THRESHOLD_MINUTES = 1440;

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

            // Waiting count: from MessagingSession records currently in 'Waiting'.
            Map<Id, Integer> waitingByQueue = countWaitingMessagingSessions(queueIds);

            // Queue names are required for the SDO custom-object EWT fallback.
            Map<Id, Group> queueGroups = new Map<Id, Group>([
                SELECT Id, Name
                FROM Group
                WHERE Id IN :queueIds
                AND Type = 'Queue'
                WITH SECURITY_ENFORCED
            ]);

            // EWT: hybrid chain — PSR → MessagingSession → SDO → default 0.
            // First source that runs without QueryException wins for ALL queues
            // (we never mix sources across queues to keep numbers comparable).
            Map<Id, Integer> ewtByQueue = resolveEwtPerQueue(queueIds, queueGroups);

            for (Id queueId : queueIds) {
                Integer waiting = waitingByQueue.containsKey(queueId)
                    ? waitingByQueue.get(queueId)
                    : 0;
                Integer ewt = ewtByQueue.containsKey(queueId)
                    ? ewtByQueue.get(queueId)
                    : 0;
                result.put(queueId, new QueueMetric(waiting, ewt));
            }
            return result;
        }

        private Map<Id, Integer> countWaitingMessagingSessions(Set<Id> queueIds) {
            Map<Id, Integer> waitingByQueue = new Map<Id, Integer>();
            try {
                DateTime staleCutoff = DateTime.now().addMinutes(-STALE_THRESHOLD_MINUTES);
                for (SObject session : Database.query(
                    'SELECT OwnerId FROM MessagingSession ' +
                    'WHERE OwnerId IN :queueIds ' +
                    'AND Status = \'Waiting\' ' +
                    'AND CreatedDate >= :staleCutoff'
                )) {
                    Id ownerId = (Id) session.get('OwnerId');
                    Integer currentCount = waitingByQueue.containsKey(ownerId)
                        ? waitingByQueue.get(ownerId)
                        : 0;
                    waitingByQueue.put(ownerId, currentCount + 1);
                }
            } catch (Exception ex) {
                // MessagingSession not available in this org → empty map.
            }
            return waitingByQueue;
        }

        // -------------------------------------------------------------------
        // EWT chain: try the most canonical source first, fall back on failure.
        //
        // Each helper returns null when its source object/field is not
        // queryable (QueryException) — meaning "I don't know, try the next".
        // It returns a (possibly empty) map when the query ran successfully:
        // an empty map means "0 wait time for all queues" (nothing pending).
        // -------------------------------------------------------------------
        private Map<Id, Integer> resolveEwtPerQueue(Set<Id> queueIds, Map<Id, Group> queueGroups) {
            Map<Id, Integer> ewt;

            // 1) PendingServiceRouting — canonical Omni-Channel source.
            ewt = resolveEwtFromPendingServiceRouting(queueIds);
            if (ewt != null) {
                return ewt;
            }

            // 2) MessagingSession — channel-specific, but always available
            //    when Messaging is provisioned.
            ewt = resolveEwtFromMessagingSession(queueIds);
            if (ewt != null) {
                return ewt;
            }

            // 3) SDO_Service_Queue_Stat__c — demo-org custom object.
            ewt = resolveEwtFromSdoStats(queueIds, queueGroups);
            if (ewt != null) {
                return ewt;
            }

            // 4) Default: 0 minutes for every queue.
            Map<Id, Integer> defaults = new Map<Id, Integer>();
            for (Id queueId : queueIds) {
                defaults.put(queueId, 0);
            }
            return defaults;
        }

        private Map<Id, Integer> resolveEwtFromPendingServiceRouting(Set<Id> queueIds) {
            Map<Id, Integer> ewt = new Map<Id, Integer>();
            try {
                // Oldest still-pending item per queue → its age is the current EWT.
                DateTime now = DateTime.now();
                DateTime staleCutoff = now.addMinutes(-STALE_THRESHOLD_MINUTES);
                List<AggregateResult> aggregates = Database.query(
                    'SELECT QueueId qid, MIN(CreatedDate) oldest ' +
                    'FROM PendingServiceRouting ' +
                    'WHERE QueueId IN :queueIds ' +
                    'AND IsReadyForRouting = true ' +
                    'AND CreatedDate >= :staleCutoff ' +
                    'GROUP BY QueueId'
                );
                for (AggregateResult agg : aggregates) {
                    Id qid = (Id) agg.get('qid');
                    DateTime oldest = (DateTime) agg.get('oldest');
                    if (oldest != null) {
                        Long ageMs = now.getTime() - oldest.getTime();
                        ewt.put(qid, Integer.valueOf(ageMs / (1000L * 60L)));
                    }
                }
                // Queues with no pending item → EWT = 0 (real value, not unknown).
                for (Id queueId : queueIds) {
                    if (!ewt.containsKey(queueId)) {
                        ewt.put(queueId, 0);
                    }
                }
                return ewt;
            } catch (QueryException qe) {
                return null;
            }
        }

        private Map<Id, Integer> resolveEwtFromMessagingSession(Set<Id> queueIds) {
            Map<Id, Integer> ewt = new Map<Id, Integer>();
            try {
                DateTime now = DateTime.now();
                DateTime staleCutoff = now.addMinutes(-STALE_THRESHOLD_MINUTES);
                List<AggregateResult> aggregates = Database.query(
                    'SELECT OwnerId qid, MIN(CreatedDate) oldest ' +
                    'FROM MessagingSession ' +
                    'WHERE OwnerId IN :queueIds ' +
                    'AND Status = \'Waiting\' ' +
                    'AND CreatedDate >= :staleCutoff ' +
                    'GROUP BY OwnerId'
                );
                for (AggregateResult agg : aggregates) {
                    Id qid = (Id) agg.get('qid');
                    DateTime oldest = (DateTime) agg.get('oldest');
                    if (oldest != null) {
                        Long ageMs = now.getTime() - oldest.getTime();
                        ewt.put(qid, Integer.valueOf(ageMs / (1000L * 60L)));
                    }
                }
                for (Id queueId : queueIds) {
                    if (!ewt.containsKey(queueId)) {
                        ewt.put(queueId, 0);
                    }
                }
                return ewt;
            } catch (QueryException qe) {
                return null;
            }
        }

        private Map<Id, Integer> resolveEwtFromSdoStats(Set<Id> queueIds, Map<Id, Group> queueGroups) {
            Set<String> queueNames = new Set<String>();
            for (Group g : queueGroups.values()) {
                queueNames.add(g.Name);
            }
            Map<String, QueueMetric> byName = resolveMetricsByQueueName(queueNames);
            if (byName.isEmpty()) {
                return null;
            }
            Map<Id, Integer> ewt = new Map<Id, Integer>();
            for (Id queueId : queueIds) {
                String name = queueGroups.get(queueId) == null ? null : queueGroups.get(queueId).Name;
                QueueMetric m = name == null ? null : byName.get(name);
                ewt.put(queueId, m == null || m.ewtMinutes == null ? 0 : m.ewtMinutes);
            }
            return ewt;
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
    //
    // Flag semantics (each one is independent and explicit):
    //
    //   policyResolved            : we found a PresenceUserConfig for the user
    //                              and successfully read its options flag.
    //   allowAnyDestinationQueue  : value of OptionsIsAllowAnyDestinationQueue...
    //                              (default = false  → restrictive / fail-closed).
    //   assignmentQueryAttempted  : we attempted at least one schema-specific
    //                              query for the assigned queues.
    //   assignmentQuerySucceeded  : at least one of the queries returned without
    //                              QueryException.  An empty result counts as
    //                              "succeeded" — it means "admin configured no
    //                              queues", not "we don't know which queues".
    //   assignedQueueIds          : queue IDs returned by the successful query.
    //   diagnosticMessage         : non-null whenever a degraded mode was used,
    //                              for surfacing to the LWC / Apex log.
    // -----------------------------------------------------------------------
    public class PresenceTransferPolicy {
        public Boolean policyResolved           = false;
        public Boolean allowAnyDestinationQueue = false;  // fail-closed default
        public Boolean assignmentQueryAttempted = false;
        public Boolean assignmentQuerySucceeded = false;
        public Set<Id> assignedQueueIds         = new Set<Id>();
        public String  configMasterLabel;
        public String  diagnosticMessage;
    }

    @TestVisible private static QueueAnalyticsProvider    providerOverride;
    @TestVisible private static PresenceTransferPolicy    policyOverride;

    // -----------------------------------------------------------------------
    // resolvePresenceTransferPolicy
    //   1. Find PresenceUserConfig for the running user:
    //        user-level   → PresenceUserConfigUser   (wins if present)
    //        profile-level→ PresenceUserConfigProfile (fallback only)
    //      This mirrors the platform's documented precedence:
    //      https://help.salesforce.com/s/articleView?id=service.presence_users.htm
    //   2. Read OptionsIsAllowAnyDestinationQueueForTransferEnabled.
    //      A null value is treated as `false` (fail-closed).
    //   3. If restrictive, attempt to load the assigned queue IDs by trying
    //      every known schema variation:
    //        a) UserConfigTransferQueue (Enhanced Omni-Channel — modern)
    //        b) UserConfigTransferButton.LiveChatButton.QueueId (legacy Live Chat)
    //      The first one that runs without QueryException wins.
    //      A successful query that returns zero rows means
    //      "admin configured no queues" and is honoured as such.
    // -----------------------------------------------------------------------
    @TestVisible
    private static PresenceTransferPolicy resolvePresenceTransferPolicy() {
        if (policyOverride != null) {
            return policyOverride;
        }

        PresenceTransferPolicy policy = new PresenceTransferPolicy();
        Id configId = locatePresenceUserConfigId(policy);
        if (configId == null) {
            // No presence config assigned to user nor profile → unrestricted
            // is the documented platform default for users without a config.
            policy.policyResolved           = true;
            policy.allowAnyDestinationQueue = true;
            return policy;
        }

        if (!readPresencePolicyFlag(configId, policy)) {
            // Could not read the config record (FLS / object disabled).
            // Stay fail-closed: policyResolved=false, allowAny=false.
            return policy;
        }
        policy.policyResolved = true;

        if (policy.allowAnyDestinationQueue) {
            return policy;
        }

        loadAssignedQueueIds(configId, policy);
        return policy;
    }

    // Step 1 — resolve the active PresenceUserConfigId for the running user.
    // Returns null if no config is assigned at user OR profile level.
    private static Id locatePresenceUserConfigId(PresenceTransferPolicy policy) {
        Id userId    = UserInfo.getUserId();
        Id profileId = UserInfo.getProfileId();

        try {
            List<SObject> byUser = Database.query(
                'SELECT PresenceUserConfigId FROM PresenceUserConfigUser ' +
                'WHERE UserId = :userId LIMIT 1'
            );
            if (!byUser.isEmpty()) {
                return (Id) byUser[0].get('PresenceUserConfigId');
            }

            List<SObject> byProfile = Database.query(
                'SELECT PresenceUserConfigId FROM PresenceUserConfigProfile ' +
                'WHERE ProfileId = :profileId LIMIT 1'
            );
            if (!byProfile.isEmpty()) {
                return (Id) byProfile[0].get('PresenceUserConfigId');
            }
        } catch (QueryException qe) {
            policy.diagnosticMessage = 'PresenceUserConfig objects not queryable: ' + qe.getMessage();
        }
        return null;
    }

    // Step 2 — read the policy flag. Returns true on successful read,
    // false otherwise (caller decides what to do).
    private static Boolean readPresencePolicyFlag(Id configId, PresenceTransferPolicy policy) {
        try {
            List<SObject> configs = Database.query(
                'SELECT MasterLabel, OptionsIsAllowAnyDestinationQueueForTransferEnabled ' +
                'FROM PresenceUserConfig WHERE Id = :configId LIMIT 1'
            );
            if (configs.isEmpty()) {
                policy.diagnosticMessage = 'PresenceUserConfig ' + configId + ' not visible to running user.';
                return false;
            }

            policy.configMasterLabel = (String) configs[0].get('MasterLabel');

            // Null-safe boolean read: a missing value defaults to `false`
            // (= restrictive) to match the platform's safer behaviour and
            // avoid an NPE on the cast.
            Object rawFlag = configs[0].get('OptionsIsAllowAnyDestinationQueueForTransferEnabled');
            policy.allowAnyDestinationQueue = rawFlag != null && (Boolean) rawFlag;
            return true;
        } catch (QueryException qe) {
            policy.diagnosticMessage = 'PresenceUserConfig not readable: ' + qe.getMessage();
            return false;
        }
    }

    // Step 3 — try every known schema for the assigned queue list.
    // Sets assignmentQueryAttempted = true. assignmentQuerySucceeded reflects
    // whether at least one query ran without QueryException (empty result still
    // counts as success — "admin configured zero queues").
    private static void loadAssignedQueueIds(Id configId, PresenceTransferPolicy policy) {
        policy.assignmentQueryAttempted = true;

        // 3a) Modern Enhanced Omni-Channel schema.
        try {
            List<SObject> rows = Database.query(
                'SELECT QueueId FROM UserConfigTransferQueue ' +
                'WHERE PresenceUserConfigId = :configId AND QueueId != null'
            );
            for (SObject r : rows) {
                policy.assignedQueueIds.add((Id) r.get('QueueId'));
            }
            policy.assignmentQuerySucceeded = true;
            return;
        } catch (QueryException qe) {
            // Object/field not available in this org — try the legacy schema next.
        }

        // 3b) Legacy Live Chat schema:
        //     UserConfigTransferButton (LiveChatUserConfigId, LiveChatButtonId)
        //     LiveChatButton (Id, QueueId)
        //
        //     We need the LiveChatUserConfigId that corresponds to the same
        //     presence config — in many orgs there is a 1:1 link via the
        //     LiveChatUserConfig.DeveloperName / PresenceUserConfig.DeveloperName
        //     convention. We try them in turn.
        try {
            // First try: assume PresenceUserConfigId is exposed directly.
            List<SObject> rows = Database.query(
                'SELECT LiveChatButtonId FROM UserConfigTransferButton ' +
                'WHERE PresenceUserConfigId = :configId AND LiveChatButtonId != null'
            );
            Set<Id> buttonIds = new Set<Id>();
            for (SObject r : rows) {
                buttonIds.add((Id) r.get('LiveChatButtonId'));
            }
            if (!buttonIds.isEmpty()) {
                List<SObject> buttons = Database.query(
                    'SELECT QueueId FROM LiveChatButton ' +
                    'WHERE Id IN :buttonIds AND QueueId != null'
                );
                for (SObject b : buttons) {
                    policy.assignedQueueIds.add((Id) b.get('QueueId'));
                }
            }
            policy.assignmentQuerySucceeded = true;
            return;
        } catch (QueryException qe) {
            // Direct PresenceUserConfigId not exposed on UserConfigTransferButton.
        }

        // 3c) Neither modern nor legacy schemas are queryable in this org.
        // Fail-closed: assignmentQuerySucceeded stays false.  The caller
        // (getTransferQueues) will return an empty list with diagnosticMessage.
        policy.diagnosticMessage = 'Org does not expose any queryable assignment'
            + ' object (UserConfigTransferQueue / UserConfigTransferButton.PresenceUserConfigId).'
            + ' Component will return no queues until Enhanced Omni-Channel is enabled'
            + ' or a custom mapping is provided.';
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

        // Narrow the universe to queues that actually have an Omni-Channel
        // QueueRoutingConfig attached — i.e. queues that the platform can
        // route work items to.  Queues without a routing config are "ghost"
        // QueueSobject entries that wouldn't accept transfers anyway.
        //
        // Skipped during Apex tests because QueueRoutingConfig is a setup-only
        // object that test fixtures cannot create without elevated permissions;
        // this refinement is a runtime-only improvement.
        if (!Test.isRunningTest() && !queueIdsFromSobject.isEmpty()) {
            Set<Id> omniRoutableQueueIds = new Set<Id>();
            for (Group routableQueue : [
                SELECT Id
                FROM Group
                WHERE Id IN :queueIdsFromSobject
                AND Type = 'Queue'
                AND QueueRoutingConfigId != null
                WITH SECURITY_ENFORCED
            ]) {
                omniRoutableQueueIds.add(routableQueue.Id);
            }
            // Only apply the filter if it actually narrows the set to a
            // non-empty list; if the org has no routing config at all, keep
            // the original universe to avoid an empty UI.
            if (!omniRoutableQueueIds.isEmpty()) {
                queueIdsFromSobject = omniRoutableQueueIds;
            }
        }

        Set<Id> eligibleQueueIds;

        if (policy.allowAnyDestinationQueue) {
            // PresenceUserConfig allows any destination queue.
            eligibleQueueIds = queueIdsFromSobject;
        } else if (policy.assignmentQuerySucceeded) {
            // Restrictive policy, assignment list resolved successfully.
            // Honour the admin's intent strictly — including an empty list,
            // which means "no transfer queues allowed for this user".
            eligibleQueueIds = new Set<Id>();
            for (Id qId : policy.assignedQueueIds) {
                if (queueIdsFromSobject.contains(qId)) {
                    eligibleQueueIds.add(qId);
                }
            }
            // Empty intersection (admin configured queues that aren't mapped
            // to this SObject type) → return empty rather than opening the
            // gate.  This surfaces the misconfiguration instead of masking it.
        } else {
            // Restrictive policy BUT the running org does not expose any
            // schema we can query for the assigned queues.  Two pragmatic
            // options exist here:
            //
            //   (a) Fail-closed → return [] and force the admin to either
            //       enable Enhanced Omni-Channel or set OptionsIsAllowAny... = true.
            //   (b) Graceful degradation → return all QueueSobject queues for
            //       the SObject type, with a WARN logged for traceability.
            //
            // We pick (b) because the platform itself doesn't expose the
            // data publicly in this configuration — a fail-closed component
            // would be unusable in any Standard Omni-Channel org.  The
            // diagnosticMessage is logged for admins to investigate.
            System.debug(LoggingLevel.WARN,
                'EnhancedQueueTransfer: schema for assigned queues not available; '
                + 'falling back to QueueSobject. ' + policy.diagnosticMessage);
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
