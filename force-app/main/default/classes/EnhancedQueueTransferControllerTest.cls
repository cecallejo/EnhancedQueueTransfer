@IsTest
private class EnhancedQueueTransferControllerTest {
    private class DeterministicProvider implements EnhancedQueueTransferController.QueueAnalyticsProvider {
        public Map<Id, EnhancedQueueTransferController.QueueMetric> getMetrics(Set<Id> queueIds) {
            Map<Id, EnhancedQueueTransferController.QueueMetric> result =
                new Map<Id, EnhancedQueueTransferController.QueueMetric>();
            Integer index = 1;
            for (Id queueId : queueIds) {
                result.put(queueId, new EnhancedQueueTransferController.QueueMetric(index, index + 1));
                index++;
            }
            return result;
        }
    }

    @TestSetup
    static void setupData() {
        Group queueGroup = new Group(
            Name = 'Support Queue Alpha',
            Type = 'Queue'
        );
        Group secondQueue = new Group(
            Name = 'Billing Queue Beta',
            Type = 'Queue'
        );
        insert new List<Group>{ queueGroup, secondQueue };

        insert new List<QueueSobject>{
            new QueueSobject(
                QueueId = queueGroup.Id,
                SobjectType = 'Case'
            ),
            new QueueSobject(
                QueueId = secondQueue.Id,
                SobjectType = 'Case'
            )
        };

        insert new List<GroupMember>{
            new GroupMember(
                GroupId = queueGroup.Id,
                UserOrGroupId = UserInfo.getUserId()
            ),
            new GroupMember(
                GroupId = secondQueue.Id,
                UserOrGroupId = UserInfo.getUserId()
            )
        };
    }

    @IsTest
    static void getTransferQueues_returnsEligibleQueuesWithMetrics() {
        // Force allowAny=true so the test does not depend on the running
        // user's actual PresenceUserConfig (which may be restrictive in the
        // org where the test is deployed).
        EnhancedQueueTransferController.PresenceTransferPolicy openPolicy =
            new EnhancedQueueTransferController.PresenceTransferPolicy();
        openPolicy.policyResolved           = true;
        openPolicy.allowAnyDestinationQueue = true;
        EnhancedQueueTransferController.policyOverride   = openPolicy;
        EnhancedQueueTransferController.providerOverride = new DeterministicProvider();

        Test.startTest();
        List<EnhancedQueueTransferController.TransferQueueView> rows =
            EnhancedQueueTransferController.getTransferQueues('Case', null);
        Test.stopTest();

        Assert.isTrue(!rows.isEmpty(), 'Expected at least one queue row.');
        Assert.areEqual(true, rows[0].canTransfer, 'Row must be marked as transferable.');
        Assert.areEqual(1, rows[0].waitingCount, 'Deterministic waiting count expected.');
        Assert.areEqual(2, rows[0].ewtMinutes, 'Deterministic EWT expected.');

        EnhancedQueueTransferController.policyOverride   = null;
        EnhancedQueueTransferController.providerOverride = null;
    }

    @IsTest
    static void transferRecordToQueue_updatesOwnerToQueue() {
        Group queueGroup = [SELECT Id FROM Group WHERE Name = 'Support Queue Alpha' LIMIT 1];
        Case queueCase = new Case(
            Subject = 'Transfer test case',
            Origin = 'Phone',
            Status = 'New'
        );
        insert queueCase;

        Test.startTest();
        Boolean transferSucceeded = false;
        try {
            EnhancedQueueTransferController.transferRecordToQueue(queueCase.Id, queueGroup.Id);
            transferSucceeded = true;
        } catch (DmlException ex) {
            Assert.isTrue(
                ex.getMessage().contains('CANNOT_EXECUTE_FLOW_TRIGGER'),
                'Unexpected transfer failure: ' + ex.getMessage()
            );
        }
        Test.stopTest();

        if (transferSucceeded) {
            Case updatedCase = [SELECT Id, OwnerId FROM Case WHERE Id = :queueCase.Id LIMIT 1];
            Assert.areEqual(queueGroup.Id, updatedCase.OwnerId, 'Owner must be updated to queue.');
        }
    }

    @IsTest
    static void getTransferQueues_throwsForUnsupportedObject() {
        Boolean hasThrown = false;
        try {
            EnhancedQueueTransferController.getTransferQueues('Lead', null);
        } catch (AuraHandledException ex) {
            hasThrown = true;
        }
        Assert.isTrue(hasThrown, 'Expected object support validation error.');
    }

    @IsTest
    static void getTransferQueues_restrictivePolicyWithFailedAssignmentQuery_returnsEmpty() {
        // Restrictive policy + assignment query failed → fail-closed empty list.
        EnhancedQueueTransferController.PresenceTransferPolicy failClosedPolicy =
            new EnhancedQueueTransferController.PresenceTransferPolicy();
        failClosedPolicy.policyResolved           = true;
        failClosedPolicy.allowAnyDestinationQueue = false;
        failClosedPolicy.assignmentQueryAttempted = true;
        failClosedPolicy.assignmentQuerySucceeded = false;
        failClosedPolicy.diagnosticMessage       = 'Schema not available';

        EnhancedQueueTransferController.policyOverride  = failClosedPolicy;
        EnhancedQueueTransferController.providerOverride = new DeterministicProvider();

        Test.startTest();
        List<EnhancedQueueTransferController.TransferQueueView> rows =
            EnhancedQueueTransferController.getTransferQueues('Case', null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'Restrictive policy with failed assignment query must return zero rows (fail-closed).');

        EnhancedQueueTransferController.policyOverride  = null;
        EnhancedQueueTransferController.providerOverride = null;
    }

    @IsTest
    static void getTransferQueues_restrictivePolicyWithAssignedQueues_returnsIntersection() {
        // Restrictive policy + resolved assignments → intersection with QueueSobject.
        Group billingQueue = [SELECT Id FROM Group WHERE Name = 'Billing Queue Beta' LIMIT 1];

        EnhancedQueueTransferController.PresenceTransferPolicy strictPolicy =
            new EnhancedQueueTransferController.PresenceTransferPolicy();
        strictPolicy.policyResolved           = true;
        strictPolicy.allowAnyDestinationQueue = false;
        strictPolicy.assignmentQueryAttempted = true;
        strictPolicy.assignmentQuerySucceeded = true;
        strictPolicy.assignedQueueIds.add(billingQueue.Id);

        EnhancedQueueTransferController.policyOverride  = strictPolicy;
        EnhancedQueueTransferController.providerOverride = new DeterministicProvider();

        Test.startTest();
        List<EnhancedQueueTransferController.TransferQueueView> rows =
            EnhancedQueueTransferController.getTransferQueues('Case', null);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the explicitly-assigned queue should appear.');
        Assert.areEqual(billingQueue.Id, rows[0].queueId, 'Returned queue must be the assigned one.');

        EnhancedQueueTransferController.policyOverride  = null;
        EnhancedQueueTransferController.providerOverride = null;
    }

    @IsTest
    static void getTransferQueues_restrictivePolicyZeroAssignments_returnsEmpty() {
        // Restrictive policy + assignment query succeeded with zero rows →
        // honour admin's intent (no queues allowed).  Was previously
        // mis-handled as "fall back to all queues".
        EnhancedQueueTransferController.PresenceTransferPolicy emptyPolicy =
            new EnhancedQueueTransferController.PresenceTransferPolicy();
        emptyPolicy.policyResolved           = true;
        emptyPolicy.allowAnyDestinationQueue = false;
        emptyPolicy.assignmentQueryAttempted = true;
        emptyPolicy.assignmentQuerySucceeded = true;
        // assignedQueueIds remains empty.

        EnhancedQueueTransferController.policyOverride  = emptyPolicy;
        EnhancedQueueTransferController.providerOverride = new DeterministicProvider();

        Test.startTest();
        List<EnhancedQueueTransferController.TransferQueueView> rows =
            EnhancedQueueTransferController.getTransferQueues('Case', null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'Zero assigned queues must mean zero rows, not "show all queues".');

        EnhancedQueueTransferController.policyOverride  = null;
        EnhancedQueueTransferController.providerOverride = null;
    }

    @IsTest
    static void getTransferQueues_filtersBySearchTerm() {
        EnhancedQueueTransferController.PresenceTransferPolicy openPolicy =
            new EnhancedQueueTransferController.PresenceTransferPolicy();
        openPolicy.policyResolved           = true;
        openPolicy.allowAnyDestinationQueue = true;
        EnhancedQueueTransferController.policyOverride   = openPolicy;
        EnhancedQueueTransferController.providerOverride = new DeterministicProvider();

        Test.startTest();
        List<EnhancedQueueTransferController.TransferQueueView> rows =
            EnhancedQueueTransferController.getTransferQueues('Case', 'Billing');
        Test.stopTest();

        Assert.isTrue(!rows.isEmpty(), 'Search should return matching queues.');
        Boolean foundBillingQueue = false;
        for (EnhancedQueueTransferController.TransferQueueView row : rows) {
            Assert.isTrue(
                row.queueName.contains('Billing'),
                'All returned rows must match search term.'
            );
            if (row.queueName == 'Billing Queue Beta') {
                foundBillingQueue = true;
            }
        }
        Assert.isTrue(foundBillingQueue, 'Expected Billing Queue Beta in filtered results.');

        EnhancedQueueTransferController.policyOverride   = null;
        EnhancedQueueTransferController.providerOverride = null;
    }

    @IsTest
    static void resolvePresenceTransferPolicy_noConfig_returnsAllowAny() {
        // Run as a brand-new test user that cannot have a real
        // PresenceUserConfigUser/Profile mapping in the org.
        Profile minimalProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User isolatedUser = new User(
            Alias            = 'iso',
            Email            = 'isolated@enhancedqueuetest.example',
            EmailEncodingKey = 'UTF-8',
            LastName         = 'Isolated',
            LanguageLocaleKey= 'en_US',
            LocaleSidKey     = 'en_US',
            ProfileId        = minimalProfile.Id,
            TimeZoneSidKey   = 'America/Sao_Paulo',
            Username         = 'isolated_' + System.currentTimeMillis() + '@enhancedqueuetest.example'
        );
        insert isolatedUser;

        EnhancedQueueTransferController.PresenceTransferPolicy policy;
        System.runAs(isolatedUser) {
            Test.startTest();
            policy = EnhancedQueueTransferController.resolvePresenceTransferPolicy();
            Test.stopTest();
        }

        Assert.areEqual(true,  policy.policyResolved,           'Policy must be marked resolved.');
        Assert.areEqual(true,  policy.allowAnyDestinationQueue, 'No config = allow any (documented platform default).');
        Assert.areEqual(false, policy.assignmentQueryAttempted, 'No assignment query should be attempted.');
    }
}
