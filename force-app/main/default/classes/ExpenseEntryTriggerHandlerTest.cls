@IsTest
private class ExpenseEntryTriggerHandlerTest {
    // A past month so the "not in the future" rule never interferes.
    static final Date LAST_YEAR_MAR_15 = Date.newInstance(Date.today().year() - 1, 3, 15);

    @TestSetup
    static void setup() {
        TestDataFactory.createExpense('Rent', 'Rent', 'Monthly');
        TestDataFactory.createExpense('Tea', 'Staff Welfare', 'Daily');
    }

    static Expense__c expense(String name) {
        return [SELECT Id, Name, Total_Spent__c, Last_Entry_Date__c FROM Expense__c WHERE Name = :name WITH SYSTEM_MODE];
    }

    @IsTest
    static void monthlyEntryIsSavedOnFirstOfMonth() {
        Expense_Entry__c entry = TestDataFactory.createExpenseEntry(expense('Rent').Id, LAST_YEAR_MAR_15, 5000);

        Expense_Entry__c saved = TestDataFactory.getExpenseEntry(entry.Id);
        Assert.areEqual(LAST_YEAR_MAR_15.toStartOfMonth(), saved.Expense_Date__c, 'Monthly entry moves to the 1st');
        Assert.areEqual('Rent', saved.Category__c);
        Assert.areEqual('Monthly', saved.Expense_Type__c);
        Assert.areEqual(5000, expense('Rent').Total_Spent__c, 'Total Spent roll-up');
    }

    @IsTest
    static void dailyEntryKeepsDateAndAllowsSeveralPerDay() {
        Id teaId = expense('Tea').Id;
        TestDataFactory.insertAsSystem(
            new List<Expense_Entry__c>{
                TestDataFactory.buildExpenseEntry(teaId, LAST_YEAR_MAR_15, 30),
                TestDataFactory.buildExpenseEntry(teaId, LAST_YEAR_MAR_15, 40)
            }
        );

        Expense__c tea = expense('Tea');
        Assert.areEqual(70, tea.Total_Spent__c);
        Assert.areEqual(LAST_YEAR_MAR_15, tea.Last_Entry_Date__c, 'Daily entries keep their date');
    }

    @IsTest
    static void secondMonthlyEntryForSameMonthIsBlocked() {
        Id rentId = expense('Rent').Id;
        Expense_Entry__c first = TestDataFactory.createExpenseEntry(rentId, LAST_YEAR_MAR_15, 5000);

        Database.SaveResult result = Database.insert(
            TestDataFactory.buildExpenseEntry(rentId, LAST_YEAR_MAR_15.addDays(10), 5000),
            false,
            AccessLevel.SYSTEM_MODE
        );

        Assert.isFalse(result.isSuccess(), 'Duplicate monthly entry should fail');
        String message = result.getErrors()[0].getMessage();
        Assert.isTrue(message.contains('already has an entry'), message);
        Assert.isTrue(message.contains(TestDataFactory.getExpenseEntry(first.Id).Name), message);
    }

    @IsTest
    static void duplicateMonthlyEntriesInOneSaveAreBlocked() {
        Id rentId = expense('Rent').Id;
        List<Database.SaveResult> results = Database.insert(
            new List<Expense_Entry__c>{
                TestDataFactory.buildExpenseEntry(rentId, LAST_YEAR_MAR_15, 5000),
                TestDataFactory.buildExpenseEntry(rentId, LAST_YEAR_MAR_15.addDays(1), 5000),
                TestDataFactory.buildExpenseEntry(rentId, LAST_YEAR_MAR_15.addMonths(1), 5000)
            },
            false,
            AccessLevel.SYSTEM_MODE
        );

        Assert.isTrue(results[0].isSuccess(), 'First March entry is fine');
        Assert.isFalse(results[1].isSuccess(), 'Second March entry should fail');
        Assert.isTrue(results[1].getErrors()[0].getMessage().contains('another row in this save'));
        Assert.isTrue(results[2].isSuccess(), 'April entry is fine');
    }

    @IsTest
    static void movingMonthlyEntryIntoTakenMonthIsBlocked() {
        Id rentId = expense('Rent').Id;
        TestDataFactory.createExpenseEntry(rentId, LAST_YEAR_MAR_15, 5000);
        Expense_Entry__c april = TestDataFactory.createExpenseEntry(rentId, LAST_YEAR_MAR_15.addMonths(1), 5000);

        // Editing the amount of an existing entry is fine.
        april.Amount__c = 5500;
        TestDataFactory.updateAsSystem(april);

        april.Expense_Date__c = LAST_YEAR_MAR_15;
        Database.SaveResult result = Database.update(april, false, AccessLevel.SYSTEM_MODE);
        Assert.isFalse(result.isSuccess(), 'Moving April into March should fail');
    }

    @IsTest
    static void inactiveExpenseBlocksNewEntries() {
        Expense__c tea = expense('Tea');
        tea.Active__c = false;
        TestDataFactory.updateAsSystem(tea);

        Database.SaveResult result = Database.insert(
            TestDataFactory.buildExpenseEntry(tea.Id, LAST_YEAR_MAR_15, 30),
            false,
            AccessLevel.SYSTEM_MODE
        );
        Assert.isFalse(result.isSuccess());
        Assert.isTrue(result.getErrors()[0].getMessage().contains('inactive'), result.getErrors()[0].getMessage());
    }

    @IsTest
    static void amountMustBePositive() {
        Database.SaveResult result = Database.insert(
            TestDataFactory.buildExpenseEntry(expense('Tea').Id, LAST_YEAR_MAR_15, 0),
            false,
            AccessLevel.SYSTEM_MODE
        );
        Assert.isFalse(result.isSuccess(), 'Zero amount should fail validation');
    }

    @IsTest
    static void staffCanAddEntriesButNotDelete() {
        User staff = TestDataFactory.createUserWithPermissionSet('Nursery_Staff');
        Id teaId = expense('Tea').Id;

        System.runAs(staff) {
            Expense_Entry__c entry = TestDataFactory.buildExpenseEntry(teaId, Date.today(), 30);
            insert entry; // user mode
            Assert.isNotNull(entry.Id, 'Staff can add an expense entry');

            try {
                delete entry;
                Assert.fail('Staff should not be able to delete expense entries');
            } catch (Exception e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }
}
