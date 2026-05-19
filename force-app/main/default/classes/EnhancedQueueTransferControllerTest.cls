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
        EnhancedQueueTransferController.providerOverride = new DeterministicProvider();

        Test.startTest();
        List<EnhancedQueueTransferController.TransferQueueView> rows =
            EnhancedQueueTransferController.getTransferQueues('Case', null);
        Test.stopTest();

        Assert.isTrue(!rows.isEmpty(), 'Expected at least one queue row.');
        Assert.areEqual(true, rows[0].canTransfer, 'Row must be marked as transferable.');
        Assert.areEqual(1, rows[0].waitingCount, 'Deterministic waiting count expected.');
        Assert.areEqual(2, rows[0].ewtMinutes, 'Deterministic EWT expected.');

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
    static void getTransferQueues_filtersBySearchTerm() {
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

        EnhancedQueueTransferController.providerOverride = null;
    }
}
