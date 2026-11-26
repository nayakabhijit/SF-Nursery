@IsTest
private class PlantSaleControllerTest {
    @TestSetup
    static void setup() {
        Plant__c rose = TestDataFactory.createPlant('Rose');
        Plant__c fern = TestDataFactory.createPlant('Fern');
        TestDataFactory.createPurchase(rose.Id, 10, 50);
        TestDataFactory.createPurchase(fern.Id, 5, 20);
    }

    @IsTest
    static void savesAllRowsInOneCall() {
        Plant__c rose = TestDataFactory.getPlant('Rose');
        Plant__c fern = TestDataFactory.getPlant('Fern');
        User staff = TestDataFactory.createUserWithPermissionSet('Nursery_Staff');

        PlantSaleController.SaveResult result;
        System.runAs(staff) {
            Test.startTest();
            result = PlantSaleController.createSales(
                new List<Plant_Sale__c>{
                    TestDataFactory.buildSale(rose.Id, 4, 80),
                    TestDataFactory.buildSale(rose.Id, 3, 85),
                    TestDataFactory.buildSale(fern.Id, 5, 30)
                }
            );
            Test.stopTest();
        }

        Assert.areEqual(0, result.errors.size(), 'No row errors expected: ' + result.errors);
        Assert.areEqual(3, result.saleIds.size(), 'All three sales should be saved');
        Assert.areEqual(3, TestDataFactory.getPlant(rose.Id).Stock_Remaining__c, 'Rose stock after 7 sold');
        Assert.areEqual(0, TestDataFactory.getPlant(fern.Id).Stock_Remaining__c, 'Fern stock after 5 sold');
    }

    @IsTest
    static void oversellAcrossRowsSavesNothing() {
        Plant__c rose = TestDataFactory.getPlant('Rose');
        Plant__c fern = TestDataFactory.getPlant('Fern');
        User staff = TestDataFactory.createUserWithPermissionSet('Nursery_Staff');

        PlantSaleController.SaveResult result;
        System.runAs(staff) {
            Test.startTest();
            // Each Rose row fits on its own (10 in stock) but together they need 12.
            result = PlantSaleController.createSales(
                new List<Plant_Sale__c>{
                    TestDataFactory.buildSale(fern.Id, 1, 30),
                    TestDataFactory.buildSale(rose.Id, 6, 80),
                    TestDataFactory.buildSale(rose.Id, 6, 80)
                }
            );
            Test.stopTest();
        }

        Assert.areEqual(0, result.saleIds.size(), 'Nothing should be saved when a row fails');
        Assert.areEqual(1, result.errors.size(), 'Only the row that exceeds stock should fail');
        Assert.areEqual(2, result.errors[0].rowIndex, 'Error should point at the third row');
        Assert.isTrue(result.errors[0].message.contains('in stock'), result.errors[0].message);
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Plant_Sale__c WITH SYSTEM_MODE],
            'All rows should be rolled back'
        );
    }

    @IsTest
    static void emptyListIsRejected() {
        try {
            PlantSaleController.createSales(new List<Plant_Sale__c>());
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual('Add at least one sale.', e.getMessage());
        }
    }
}
