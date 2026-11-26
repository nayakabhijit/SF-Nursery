/**
 * Test data builders for the Nursery Stock app.
 * build* methods return unsaved records; create* methods insert them.
 *
 * API 67+ runs Apex DML/SOQL in user mode by default, and the test running user has
 * no field-level security on the app's fields. Setup DML and verification queries
 * therefore run in SYSTEM_MODE. Tests that check real user permissions do their DML
 * in default (user) mode inside System.runAs.
 */
@IsTest
public class TestDataFactory {
    // ---------- DML helpers (system mode, all-or-none) ----------

    public static void insertAsSystem(List<SObject> records) {
        Database.insert(records, true, AccessLevel.SYSTEM_MODE);
    }

    public static void insertAsSystem(SObject record) {
        Database.insert(record, true, AccessLevel.SYSTEM_MODE);
    }

    public static void updateAsSystem(SObject record) {
        Database.update(record, true, AccessLevel.SYSTEM_MODE);
    }

    public static void deleteAsSystem(List<SObject> records) {
        Database.delete(records, true, AccessLevel.SYSTEM_MODE);
    }

    public static void deleteAsSystem(SObject record) {
        Database.delete(record, true, AccessLevel.SYSTEM_MODE);
    }

    public static void undeleteAsSystem(SObject record) {
        Database.undelete(record, true, AccessLevel.SYSTEM_MODE);
    }

    // ---------- Plants ----------

    public static Plant__c buildPlant(String name) {
        return new Plant__c(Name = name, Category__c = 'Flowering', Reorder_Level__c = 5);
    }

    public static Plant__c createPlant(String name) {
        Plant__c plant = buildPlant(name);
        insertAsSystem(plant);
        return plant;
    }

    public static List<Plant__c> createPlants(Integer count, String namePrefix) {
        List<Plant__c> plants = new List<Plant__c>();
        for (Integer i = 0; i < count; i++) {
            plants.add(buildPlant(namePrefix + ' ' + i));
        }
        insertAsSystem(plants);
        return plants;
    }

    // ---------- Purchases ----------

    public static Plant_Purchase__c buildPurchase(Id plantId, Decimal quantity, Decimal unitPrice) {
        return new Plant_Purchase__c(
            Plant__c = plantId,
            Purchase_Date__c = Date.today(),
            Quantity_Purchased__c = quantity,
            Purchase_Price__c = unitPrice,
            Supplier__c = 'Test Supplier',
            Variety_Size__c = 'Standard'
        );
    }

    public static Plant_Purchase__c createPurchase(Id plantId, Decimal quantity, Decimal unitPrice) {
        Plant_Purchase__c purchase = buildPurchase(plantId, quantity, unitPrice);
        insertAsSystem(purchase);
        return purchase;
    }

    // ---------- Sales ----------

    public static Plant_Sale__c buildSale(Id plantId, Decimal quantity, Decimal sellingPrice) {
        return buildSale(plantId, quantity, sellingPrice, Date.today());
    }

    public static Plant_Sale__c buildSale(Id plantId, Decimal quantity, Decimal sellingPrice, Date saleDate) {
        return new Plant_Sale__c(
            Plant__c = plantId,
            Sale_Date__c = saleDate,
            Quantity_Sold__c = quantity,
            Selling_Price__c = sellingPrice
        );
    }

    public static Plant_Sale__c createSale(Id plantId, Decimal quantity, Decimal sellingPrice) {
        Plant_Sale__c sale = buildSale(plantId, quantity, sellingPrice);
        insertAsSystem(sale);
        return sale;
    }

    // ---------- Expenses ----------

    public static Expense__c buildExpense(String name, String category, String expenseType) {
        return new Expense__c(Name = name, Category__c = category, Expense_Type__c = expenseType, Active__c = true);
    }

    public static Expense__c createExpense(String name, String category, String expenseType) {
        Expense__c expense = buildExpense(name, category, expenseType);
        insertAsSystem(expense);
        return expense;
    }

    public static Expense_Entry__c buildExpenseEntry(Id expenseId, Date expenseDate, Decimal amount) {
        return new Expense_Entry__c(Expense__c = expenseId, Expense_Date__c = expenseDate, Amount__c = amount);
    }

    public static Expense_Entry__c createExpenseEntry(Id expenseId, Date expenseDate, Decimal amount) {
        Expense_Entry__c entry = buildExpenseEntry(expenseId, expenseDate, amount);
        insertAsSystem(entry);
        return entry;
    }

    public static Expense_Entry__c getExpenseEntry(Id entryId) {
        return [
            SELECT Id, Name, Expense__c, Expense_Date__c, Amount__c, Category__c, Expense_Type__c
            FROM Expense_Entry__c
            WHERE Id = :entryId
            WITH SYSTEM_MODE
        ];
    }

    // ---------- Re-reads (system mode) ----------

    public static Plant__c getPlant(Id plantId) {
        return [
            SELECT Id, Name, Plant_Key__c, Reorder_Level__c, Purchased_Qty__c, Total_Purchase_Cost__c,
                Sold_Qty__c, Sales_Revenue__c, Total_COGS__c, Stock_Remaining__c, Avg_Purchase_Price__c,
                Stock_Value__c, Avg_Selling_Price__c, Gross_Profit__c, Stock_Status__c
            FROM Plant__c
            WHERE Id = :plantId
            WITH SYSTEM_MODE
        ];
    }

    public static Plant__c getPlant(String name) {
        return getPlant([SELECT Id FROM Plant__c WHERE Name = :name WITH SYSTEM_MODE LIMIT 1].Id);
    }

    public static List<Plant__c> getPlants(List<Plant__c> plants) {
        return [
            SELECT Id, Name, Sold_Qty__c, Stock_Remaining__c, Sales_Revenue__c, Total_COGS__c,
                Gross_Profit__c, Stock_Status__c
            FROM Plant__c
            WHERE Id IN :plants
            WITH SYSTEM_MODE
        ];
    }

    public static Plant_Sale__c getSale(Id saleId) {
        return [
            SELECT Id, Name, Plant__c, Sale_Date__c, Quantity_Sold__c, Selling_Price__c, Unit_Cost__c,
                Sale_Revenue__c, Cost_of_Plants_Sold__c, Gross_Profit__c, Current_Stock__c,
                Stock_After_Sale__c, Stock_Check__c
            FROM Plant_Sale__c
            WHERE Id = :saleId
            WITH SYSTEM_MODE
        ];
    }

    // ---------- Users ----------

    /**
     * Creates a Standard User with the given permission set (e.g. Nursery_Admin,
     * Nursery_Staff). Setup DML runs in its own runAs block to avoid mixed-DML errors.
     */
    public static User createUserWithPermissionSet(String permissionSetName) {
        PermissionSet permSet = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName WITH SYSTEM_MODE LIMIT 1];
        User newUser = buildStandardUser(permissionSetName);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insertAsSystem(newUser);
            insertAsSystem(new PermissionSetAssignment(AssigneeId = newUser.Id, PermissionSetId = permSet.Id));
        }
        return newUser;
    }

    /**
     * Creates a Standard User with no permission sets, so no Allow_Oversell.
     * Use with System.runAs + SYSTEM_MODE DML to test the oversell / negative-stock
     * blocks independently of the user running the tests (who may hold Nursery_Admin).
     */
    public static User createUserWithoutOversell() {
        User newUser = buildStandardUser('NoOversell');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insertAsSystem(newUser);
        }
        return newUser;
    }

    private static User buildStandardUser(String lastNameSuffix) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' WITH SYSTEM_MODE LIMIT 1];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '') + DateTime.now().getTime();

        return new User(
            Alias = 'nurs' + unique.right(4),
            Email = 'nursery.' + unique + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Nursery ' + lastNameSuffix,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Asia/Kolkata',
            Username = 'nursery.' + unique + '@example.com.test'
        );
    }
}
