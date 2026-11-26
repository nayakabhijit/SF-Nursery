@IsTest
private class PlantTriggerHandlerTest {
    @IsTest
    static void nameIsNormalisedAndKeyIsSet() {
        Test.startTest();
        Plant__c plant = TestDataFactory.createPlant('  Golapa    Red  ');
        Test.stopTest();

        plant = TestDataFactory.getPlant(plant.Id);
        Assert.areEqual('Golapa Red', plant.Name, 'Extra spaces should be removed from the name');
        Assert.areEqual('golapa red', plant.Plant_Key__c, 'Key should be the lower-case normalised name');
    }

    @IsTest
    static void duplicateNameIsBlockedWithFriendlyMessage() {
        TestDataFactory.createPlant('Golapa');

        Test.startTest();
        Database.SaveResult result = Database.insert(
            TestDataFactory.buildPlant(' golapa '), false, AccessLevel.SYSTEM_MODE
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Duplicate plant name should be rejected');
        Assert.areEqual('Plant Golapa already exists.', result.getErrors()[0].getMessage());
        Assert.areEqual(1, [SELECT COUNT() FROM Plant__c WITH SYSTEM_MODE]);
    }

    @IsTest
    static void duplicateWithinSameBatchIsBlocked() {
        List<Plant__c> plants = new List<Plant__c>{
            TestDataFactory.buildPlant('Sebati'),
            TestDataFactory.buildPlant('SEBATI')
        };

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(plants, false, AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess(), 'First plant should save');
        Assert.isFalse(results[1].isSuccess(), 'Second plant with the same key should fail');
        Assert.isTrue(results[1].getErrors()[0].getMessage().contains('already exists'));
    }

    @IsTest
    static void renameToExistingNameIsBlocked() {
        TestDataFactory.createPlant('Golapa');
        Plant__c dalia = TestDataFactory.createPlant('Dalia');

        Test.startTest();
        dalia.Name = 'GOLAPA';
        Database.SaveResult result = Database.update(dalia, false, AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Renaming to an existing plant name should fail');
        Assert.areEqual('Plant Golapa already exists.', result.getErrors()[0].getMessage());
    }

    @IsTest
    static void changingCaseOfOwnNameIsAllowed() {
        Plant__c plant = TestDataFactory.createPlant('golapa');

        Test.startTest();
        plant.Name = 'Golapa';
        TestDataFactory.updateAsSystem(plant);
        Test.stopTest();

        plant = TestDataFactory.getPlant(plant.Id);
        Assert.areEqual('Golapa', plant.Name);
        Assert.areEqual('golapa', plant.Plant_Key__c);
    }

    @IsTest
    static void adminCanCreatePlantInUserMode() {
        User admin = TestDataFactory.createUserWithPermissionSet('Nursery_Admin');
        Plant__c plant = TestDataFactory.buildPlant(' Dalia ');

        Test.startTest();
        System.runAs(admin) {
            insert plant;
        }
        Test.stopTest();

        Assert.areEqual('dalia', TestDataFactory.getPlant(plant.Id).Plant_Key__c);
    }

    @IsTest
    static void bulkInsertOf200Plants() {
        List<Plant__c> plants = new List<Plant__c>();
        for (Integer i = 0; i < 200; i++) {
            plants.add(TestDataFactory.buildPlant(' Bulk  Plant ' + i + ' '));
        }

        Test.startTest();
        TestDataFactory.insertAsSystem(plants);
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Plant__c WHERE Plant_Key__c LIKE 'bulk plant %' WITH SYSTEM_MODE]);
        Assert.areEqual(1, [SELECT COUNT() FROM Plant__c WHERE Name = 'Bulk Plant 7' WITH SYSTEM_MODE]);
    }

    @IsTest
    static void keyHelperHandlesBlankNames() {
        Assert.isNull(PlantTriggerHandler.toKey('   '));
        Assert.isNull(PlantTriggerHandler.toKey(null));
        Assert.isNull(PlantTriggerHandler.normaliseName(null));
        Assert.areEqual('dalia', PlantTriggerHandler.toKey(' Dalia '));
    }

    @IsTest
    static void stockStatusFormulaCoversEveryState() {
        Plant__c inStock = TestDataFactory.createPlant('In Stock Plant');
        Plant__c lowStock = TestDataFactory.createPlant('Low Stock Plant');
        Plant__c noStock = TestDataFactory.createPlant('No Stock Plant');

        Test.startTest();
        TestDataFactory.insertAsSystem(
            new List<Plant_Purchase__c>{
                TestDataFactory.buildPurchase(inStock.Id, 50, 10),
                TestDataFactory.buildPurchase(lowStock.Id, 5, 10)
            }
        );
        Test.stopTest();

        Assert.areEqual('In stock', TestDataFactory.getPlant(inStock.Id).Stock_Status__c);
        Assert.areEqual('Low stock', TestDataFactory.getPlant(lowStock.Id).Stock_Status__c);
        Plant__c empty = TestDataFactory.getPlant(noStock.Id);
        Assert.areEqual('Out of stock', empty.Stock_Status__c);
        Assert.areEqual(0, empty.Avg_Purchase_Price__c);
        Assert.areEqual(0, empty.Avg_Selling_Price__c);
    }
}
