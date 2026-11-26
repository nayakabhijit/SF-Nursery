@IsTest
private class PlantSaleTriggerHandlerTest {
    /** Golapa: 10 units @ 10 + 10 units @ 20 -> 20 in stock, average cost 15. */
    @TestSetup
    static void setup() {
        Plant__c golapa = TestDataFactory.createPlant('Golapa');
        TestDataFactory.insertAsSystem(
            new List<Plant_Purchase__c>{
                TestDataFactory.buildPurchase(golapa.Id, 10, 10),
                TestDataFactory.buildPurchase(golapa.Id, 10, 20)
            }
        );
    }

    private static Plant__c golapa() {
        return TestDataFactory.getPlant('Golapa');
    }

    @IsTest
    static void averageCostAcrossTwoPurchases() {
        Plant__c plant = golapa();
        Assert.areEqual(20, plant.Purchased_Qty__c);
        Assert.areEqual(300, plant.Total_Purchase_Cost__c);
        Assert.areEqual(15, plant.Avg_Purchase_Price__c);

        Test.startTest();
        Plant_Sale__c sale = TestDataFactory.createSale(plant.Id, 4, 30);
        Test.stopTest();

        sale = TestDataFactory.getSale(sale.Id);
        Assert.areEqual(15, sale.Unit_Cost__c, 'Unit cost = average purchase price');
        Assert.areEqual(120, sale.Sale_Revenue__c);
        Assert.areEqual(60, sale.Cost_of_Plants_Sold__c);
        Assert.areEqual(60, sale.Gross_Profit__c);
        Assert.areEqual(16, sale.Stock_After_Sale__c);
        Assert.areEqual(16, sale.Current_Stock__c);
        Assert.areEqual('In stock', sale.Stock_Check__c);

        plant = golapa();
        Assert.areEqual(4, plant.Sold_Qty__c);
        Assert.areEqual(16, plant.Stock_Remaining__c);
        Assert.areEqual(240, plant.Stock_Value__c);
        Assert.areEqual(120, plant.Sales_Revenue__c);
        Assert.areEqual(30, plant.Avg_Selling_Price__c);
        Assert.areEqual(60, plant.Total_COGS__c);
        Assert.areEqual(60, plant.Gross_Profit__c);
        Assert.areEqual('In stock', plant.Stock_Status__c);
    }

    @IsTest
    static void oversellIsBlocked() {
        User noOversell = TestDataFactory.createUserWithoutOversell();
        Plant_Sale__c sale = TestDataFactory.buildSale(golapa().Id, 21, 30);
        Database.SaveResult result;

        Test.startTest();
        System.runAs(noOversell) {
            result = Database.insert(sale, false, AccessLevel.SYSTEM_MODE);
        }
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Selling more than stock should be blocked');
        Assert.areEqual('Only 20 units of Golapa are in stock.', result.getErrors()[0].getMessage());
        Assert.areEqual(0, [SELECT COUNT() FROM Plant_Sale__c WITH SYSTEM_MODE]);
    }

    @IsTest
    static void oversellAllowedWithCustomPermission() {
        User admin = TestDataFactory.createUserWithPermissionSet('Nursery_Admin');
        Plant_Sale__c sale = TestDataFactory.buildSale(golapa().Id, 25, 30);

        Test.startTest();
        System.runAs(admin) {
            insert sale; // user mode
        }
        Test.stopTest();

        sale = TestDataFactory.getSale(sale.Id);
        Assert.areEqual(-5, sale.Stock_After_Sale__c);
        Assert.areEqual('CHECK: oversold', sale.Stock_Check__c);
        Assert.areEqual('CHECK: oversold', golapa().Stock_Status__c);
    }

    @IsTest
    static void staffCanSellWithinStockButCannotOversell() {
        User staff = TestDataFactory.createUserWithPermissionSet('Nursery_Staff');
        Id plantId = golapa().Id;
        Database.SaveResult withinStock;
        Database.SaveResult overStock;

        Test.startTest();
        System.runAs(staff) {
            // user mode: Staff has Read on Plant only, Create on Plant Sale
            withinStock = Database.insert(TestDataFactory.buildSale(plantId, 5, 30), false);
            overStock = Database.insert(TestDataFactory.buildSale(plantId, 16, 30), false);
        }
        Test.stopTest();

        Assert.isTrue(withinStock.isSuccess(), 'Staff should be able to record a sale on a read-only plant: ' + withinStock.getErrors());
        Assert.isFalse(overStock.isSuccess(), 'Staff must not oversell');
        Assert.areEqual('Only 15 units of Golapa are in stock.', overStock.getErrors()[0].getMessage());
    }

    @IsTest
    static void bulk200SalesAcrossFivePlants() {
        List<Plant__c> plants = TestDataFactory.createPlants(5, 'Bulk Plant');
        List<Plant_Purchase__c> purchases = new List<Plant_Purchase__c>();
        for (Plant__c plant : plants) {
            purchases.add(TestDataFactory.buildPurchase(plant.Id, 100, 10));
        }
        TestDataFactory.insertAsSystem(purchases);

        // Plant k gets 20 sales dated k days ago and 20 sales dated k+5 days ago,
        // interleaved, so the running stock must follow Sale Date order.
        List<Plant_Sale__c> sales = new List<Plant_Sale__c>();
        for (Integer i = 0; i < 200; i++) {
            Integer daysAgo = Math.mod(i, 10);
            sales.add(TestDataFactory.buildSale(plants[Math.mod(i, 5)].Id, 1, 15, Date.today().addDays(-daysAgo)));
        }

        Test.startTest();
        TestDataFactory.insertAsSystem(sales);
        Test.stopTest();

        for (Plant__c plant : TestDataFactory.getPlants(plants)) {
            Assert.areEqual(40, plant.Sold_Qty__c);
            Assert.areEqual(60, plant.Stock_Remaining__c);
            Assert.areEqual(600, plant.Sales_Revenue__c);
            Assert.areEqual(400, plant.Total_COGS__c);
            Assert.areEqual(200, plant.Gross_Profit__c);
        }

        for (AggregateResult row : [
            SELECT Plant__c, MIN(Stock_After_Sale__c) minStock, MAX(Stock_After_Sale__c) maxStock
            FROM Plant_Sale__c
            WITH SYSTEM_MODE
            GROUP BY Plant__c
        ]) {
            Assert.areEqual(60, (Decimal) row.get('minStock'));
            Assert.areEqual(99, (Decimal) row.get('maxStock'));
        }

        // Older sales are consumed first, so they have the higher Stock After Sale.
        Map<Id, Date> oldestDateByPlant = new Map<Id, Date>();
        for (AggregateResult row : [
            SELECT Plant__c, MIN(Sale_Date__c) oldest
            FROM Plant_Sale__c
            WITH SYSTEM_MODE
            GROUP BY Plant__c
        ]) {
            oldestDateByPlant.put((Id) row.get('Plant__c'), (Date) row.get('oldest'));
        }
        for (Plant_Sale__c sale : [SELECT Plant__c, Sale_Date__c, Stock_After_Sale__c FROM Plant_Sale__c WITH SYSTEM_MODE]) {
            Boolean isOlder = sale.Sale_Date__c == oldestDateByPlant.get(sale.Plant__c);
            Assert.areEqual(isOlder, sale.Stock_After_Sale__c >= 80, 'Running stock must follow Sale Date order');
        }
    }

    @IsTest
    static void bulkOversellBlocksOnlyTheExcessSales() {
        List<Plant__c> plants = TestDataFactory.createPlants(5, 'Bulk Plant');
        List<Plant_Purchase__c> purchases = new List<Plant_Purchase__c>();
        for (Plant__c plant : plants) {
            purchases.add(TestDataFactory.buildPurchase(plant.Id, 30, 10));
        }
        TestDataFactory.insertAsSystem(purchases);

        List<Plant_Sale__c> sales = new List<Plant_Sale__c>();
        for (Integer i = 0; i < 200; i++) {
            sales.add(TestDataFactory.buildSale(plants[Math.mod(i, 5)].Id, 1, 15));
        }

        User noOversell = TestDataFactory.createUserWithoutOversell();
        List<Database.SaveResult> results;

        Test.startTest();
        System.runAs(noOversell) {
            results = Database.insert(sales, false, AccessLevel.SYSTEM_MODE);
        }
        Test.stopTest();

        Integer failures = 0;
        for (Database.SaveResult result : results) {
            if (!result.isSuccess()) {
                failures++;
            }
        }
        Assert.areEqual(50, failures, '10 excess sales per plant should be blocked');
        for (Plant__c plant : TestDataFactory.getPlants(plants)) {
            Assert.areEqual(0, plant.Stock_Remaining__c);
            Assert.areEqual('Out of stock', plant.Stock_Status__c);
        }
    }

    @IsTest
    static void unitCostUnchangedAfterNewPurchase() {
        Plant__c plant = golapa();
        Plant_Sale__c sale = TestDataFactory.createSale(plant.Id, 2, 30);

        Test.startTest();
        TestDataFactory.createPurchase(plant.Id, 10, 45); // new average = 750 / 30 = 25
        sale.Quantity_Sold__c = 3;
        TestDataFactory.updateAsSystem(sale);
        Test.stopTest();

        Assert.areEqual(25, golapa().Avg_Purchase_Price__c);
        sale = TestDataFactory.getSale(sale.Id);
        Assert.areEqual(15, sale.Unit_Cost__c, 'Unit cost must keep the average at the time of sale');
        Assert.areEqual(45, sale.Cost_of_Plants_Sold__c, 'COGS recalculated with the snapshotted unit cost');
    }

    @IsTest
    static void updateAddsBackOldQuantityBeforeChecking() {
        Plant_Sale__c sale = TestDataFactory.createSale(golapa().Id, 20, 30); // stock now 0
        User noOversell = TestDataFactory.createUserWithoutOversell();
        Database.SaveResult tooMany;

        Test.startTest();
        System.runAs(noOversell) {
            sale.Quantity_Sold__c = 18;
            TestDataFactory.updateAsSystem(sale);
            sale.Quantity_Sold__c = 21;
            tooMany = Database.update(sale, false, AccessLevel.SYSTEM_MODE);
        }
        Test.stopTest();

        Assert.isFalse(tooMany.isSuccess(), 'Increasing above total stock should fail');
        Assert.areEqual('Only 20 units of Golapa are in stock.', tooMany.getErrors()[0].getMessage());
        Plant_Sale__c reloaded = TestDataFactory.getSale(sale.Id);
        Assert.areEqual(18, reloaded.Quantity_Sold__c);
        Assert.areEqual(2, reloaded.Stock_After_Sale__c);
        Assert.areEqual(270, reloaded.Cost_of_Plants_Sold__c);
    }

    @IsTest
    static void updateWithoutQuantityChangeKeepsSnapshots() {
        Plant_Sale__c sale = TestDataFactory.createSale(golapa().Id, 5, 30);

        Test.startTest();
        sale.Notes__c = 'Paid in cash';
        sale.Selling_Price__c = 32;
        TestDataFactory.updateAsSystem(sale);
        Test.stopTest();

        sale = TestDataFactory.getSale(sale.Id);
        Assert.areEqual(15, sale.Stock_After_Sale__c);
        Assert.areEqual(75, sale.Cost_of_Plants_Sold__c);
        Assert.areEqual(160, sale.Sale_Revenue__c);
    }

    @IsTest
    static void saleValidationRules() {
        Id plantId = golapa().Id;
        Plant_Sale__c zeroQty = TestDataFactory.buildSale(plantId, 0, 30);
        Plant_Sale__c negativePrice = TestDataFactory.buildSale(plantId, 1, -5);
        Plant_Sale__c futureDate = TestDataFactory.buildSale(plantId, 1, 30, Date.today().addDays(3));

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(
            new List<Plant_Sale__c>{ zeroQty, negativePrice, futureDate },
            false,
            AccessLevel.SYSTEM_MODE
        );
        Test.stopTest();

        for (Database.SaveResult result : results) {
            Assert.isFalse(result.isSuccess(), 'Invalid sale should be rejected');
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Plant_Sale__c WITH SYSTEM_MODE]);
    }

    @IsTest
    static void plantCannotBeChangedAfterSave() {
        Plant__c other = TestDataFactory.createPlant('Sebati');
        TestDataFactory.createPurchase(other.Id, 10, 10);
        Plant_Sale__c sale = TestDataFactory.createSale(golapa().Id, 2, 30);

        // Plant__c is a non-reparentable master-detail, so the platform refuses the
        // change outright (the Plant_Cannot_Change validation rule is a second guard).
        Boolean blocked = false;
        Test.startTest();
        try {
            Plant_Sale__c existing = TestDataFactory.getSale(sale.Id);
            existing.Plant__c = other.Id;
            Database.update(existing, true, AccessLevel.SYSTEM_MODE);
        } catch (SObjectException e) {
            blocked = true;
        } catch (DmlException e) {
            blocked = true;
        }
        Test.stopTest();

        Assert.isTrue(blocked, 'Changing the plant on a sale should fail');
        Assert.areEqual(golapa().Id, TestDataFactory.getSale(sale.Id).Plant__c);
    }

    @IsTest
    static void deleteAndUndeleteMoveStock() {
        Plant_Sale__c sale = TestDataFactory.createSale(golapa().Id, 5, 30);
        Assert.areEqual(15, golapa().Stock_Remaining__c);

        Test.startTest();
        TestDataFactory.deleteAsSystem(sale);
        Assert.areEqual(20, golapa().Stock_Remaining__c, 'Deleting a sale returns stock');
        TestDataFactory.undeleteAsSystem(sale);
        Test.stopTest();

        Assert.areEqual(15, golapa().Stock_Remaining__c, 'Undeleting a sale takes stock again');
    }
}
