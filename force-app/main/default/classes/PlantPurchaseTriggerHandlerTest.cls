@IsTest
private class PlantPurchaseTriggerHandlerTest {
    @IsTest
    static void deleteAllowedWhenStockStaysNonNegative() {
        Plant__c plant = TestDataFactory.createPlant('Golapa');
        Plant_Purchase__c purchase = TestDataFactory.createPurchase(plant.Id, 10, 10);

        Test.startTest();
        TestDataFactory.deleteAsSystem(purchase);
        Test.stopTest();

        Assert.areEqual(0, TestDataFactory.getPlant(plant.Id).Stock_Remaining__c);
    }

    @IsTest
    static void deleteBlockedWhenStockWouldGoNegative() {
        Plant__c plant = TestDataFactory.createPlant('Golapa');
        Plant_Purchase__c purchase = TestDataFactory.createPurchase(plant.Id, 10, 10);
        TestDataFactory.createSale(plant.Id, 8, 20);
        User noOversell = TestDataFactory.createUserWithoutOversell();
        Database.DeleteResult result;

        Test.startTest();
        System.runAs(noOversell) {
            result = Database.delete(purchase, false, AccessLevel.SYSTEM_MODE);
        }
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Delete should be blocked');
        Assert.isTrue(
            result.getErrors()[0].getMessage().contains('would make stock negative'),
            result.getErrors()[0].getMessage()
        );
        Assert.areEqual(2, TestDataFactory.getPlant(plant.Id).Stock_Remaining__c);
    }

    @IsTest
    static void bulkDeleteCountsPurchasesOfSamePlantTogether() {
        Plant__c plant = TestDataFactory.createPlant('Golapa');
        List<Plant_Purchase__c> purchases = new List<Plant_Purchase__c>{
            TestDataFactory.buildPurchase(plant.Id, 10, 10),
            TestDataFactory.buildPurchase(plant.Id, 10, 10)
        };
        TestDataFactory.insertAsSystem(purchases);
        TestDataFactory.createSale(plant.Id, 5, 20); // stock 15
        User noOversell = TestDataFactory.createUserWithoutOversell();
        List<Database.DeleteResult> results;

        Test.startTest();
        System.runAs(noOversell) {
            results = Database.delete(purchases, false, AccessLevel.SYSTEM_MODE);
        }
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess(), 'First delete leaves 5 in stock and should succeed');
        Assert.isFalse(results[1].isSuccess(), 'Second delete would leave -5 and should fail');
        Assert.areEqual(5, TestDataFactory.getPlant(plant.Id).Stock_Remaining__c);
    }

    @IsTest
    static void deleteAllowedWithAllowOversellPermission() {
        User admin = TestDataFactory.createUserWithPermissionSet('Nursery_Admin');
        Plant__c plant = TestDataFactory.createPlant('Golapa');
        Plant_Purchase__c purchase = TestDataFactory.createPurchase(plant.Id, 10, 10);
        TestDataFactory.createSale(plant.Id, 8, 20);

        Test.startTest();
        System.runAs(admin) {
            delete purchase; // user mode: Nursery Admin has delete + Allow_Oversell
        }
        Test.stopTest();

        Plant__c reloaded = TestDataFactory.getPlant(plant.Id);
        Assert.areEqual(-8, reloaded.Stock_Remaining__c);
        Assert.areEqual('CHECK: oversold', reloaded.Stock_Status__c);
    }

    @IsTest
    static void staffCannotDeletePurchases() {
        User staff = TestDataFactory.createUserWithPermissionSet('Nursery_Staff');
        Plant__c plant = TestDataFactory.createPlant('Golapa');
        Plant_Purchase__c purchase = TestDataFactory.createPurchase(plant.Id, 10, 10);
        Database.DeleteResult result;

        Test.startTest();
        System.runAs(staff) {
            result = Database.delete(purchase, false); // user mode: Nursery Staff has no delete
        }
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Nursery Staff must not be able to delete purchases');
        Assert.areEqual(10, TestDataFactory.getPlant(plant.Id).Stock_Remaining__c);
    }

    @IsTest
    static void bulkDeleteOf200Purchases() {
        List<Plant__c> plants = TestDataFactory.createPlants(5, 'Bulk Plant');
        List<Plant_Purchase__c> purchases = new List<Plant_Purchase__c>();
        for (Integer i = 0; i < 200; i++) {
            purchases.add(TestDataFactory.buildPurchase(plants[Math.mod(i, 5)].Id, 2, 10));
        }
        TestDataFactory.insertAsSystem(purchases);

        Test.startTest();
        TestDataFactory.deleteAsSystem(purchases);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Plant_Purchase__c WITH SYSTEM_MODE]);
    }

    @IsTest
    static void purchaseValidationRules() {
        Plant__c plant = TestDataFactory.createPlant('Golapa');
        Plant_Purchase__c zeroQty = TestDataFactory.buildPurchase(plant.Id, 0, 10);
        Plant_Purchase__c negativePrice = TestDataFactory.buildPurchase(plant.Id, 5, -1);
        Plant_Purchase__c futureDate = TestDataFactory.buildPurchase(plant.Id, 5, 10);
        futureDate.Purchase_Date__c = Date.today().addDays(5);

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(
            new List<Plant_Purchase__c>{ zeroQty, negativePrice, futureDate },
            false,
            AccessLevel.SYSTEM_MODE
        );
        Test.stopTest();

        for (Database.SaveResult result : results) {
            Assert.isFalse(result.isSuccess(), 'Invalid purchase should be rejected');
        }
        Plant_Purchase__c valid = TestDataFactory.createPurchase(plant.Id, 3, 12.5);
        Assert.areEqual(
            37.5,
            [SELECT Purchase_Cost__c FROM Plant_Purchase__c WHERE Id = :valid.Id WITH SYSTEM_MODE].Purchase_Cost__c
        );
    }
}
