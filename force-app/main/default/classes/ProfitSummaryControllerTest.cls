@IsTest
private class ProfitSummaryControllerTest {
    // All figures are in last year so no date is in the future.
    static final Integer YEAR = Date.today().year() - 1;

    @TestSetup
    static void setup() {
        Plant__c rose = TestDataFactory.createPlant('Rose');
        TestDataFactory.createPurchase(rose.Id, 10, 50); // avg cost 50

        // Jan: 4 x 80 = 320 revenue, 200 cost, 120 gross profit
        // Mar: 2 x 100 = 200 revenue, 100 cost, 100 gross profit
        TestDataFactory.insertAsSystem(
            new List<Plant_Sale__c>{
                TestDataFactory.buildSale(rose.Id, 4, 80, Date.newInstance(YEAR, 1, 20)),
                TestDataFactory.buildSale(rose.Id, 2, 100, Date.newInstance(YEAR, 3, 5))
            }
        );

        Expense__c rent = TestDataFactory.createExpense('Rent', 'Rent', 'Monthly');
        Expense__c tea = TestDataFactory.createExpense('Tea', 'Staff Welfare', 'Daily');
        TestDataFactory.insertAsSystem(
            new List<Expense_Entry__c>{
                TestDataFactory.buildExpenseEntry(rent.Id, Date.newInstance(YEAR, 1, 15), 5000),
                TestDataFactory.buildExpenseEntry(tea.Id, Date.newInstance(YEAR, 1, 10), 30),
                TestDataFactory.buildExpenseEntry(tea.Id, Date.newInstance(YEAR, 3, 5), 30),
                // Other years are excluded.
                TestDataFactory.buildExpenseEntry(tea.Id, Date.newInstance(YEAR - 1, 12, 31), 999)
            }
        );
    }

    @IsTest
    static void calculatesNetProfitByMonth() {
        User admin = TestDataFactory.createUserWithPermissionSet('Nursery_Admin');

        ProfitSummaryController.Summary summary;
        System.runAs(admin) {
            Test.startTest();
            summary = ProfitSummaryController.getSummary(YEAR);
            Test.stopTest();
        }

        Assert.areEqual(YEAR, summary.year);
        Assert.isNull(summary.currentMonth, 'Last year has no current month');
        Assert.areEqual(YEAR - 1, summary.firstYear, 'Earliest entry is in the year before');
        Assert.areEqual(12, summary.months.size());

        ProfitSummaryController.PeriodRow jan = summary.months[0];
        Assert.areEqual(320, jan.sales);
        Assert.areEqual(200, jan.costOfPlantsSold);
        Assert.areEqual(120, jan.grossProfit);
        Assert.areEqual(5030, jan.expenses);
        Assert.areEqual(-4910, jan.netProfit);

        ProfitSummaryController.PeriodRow mar = summary.months[2];
        Assert.areEqual(100, mar.grossProfit);
        Assert.areEqual(30, mar.expenses);
        Assert.areEqual(70, mar.netProfit);
        Assert.areEqual(0.35, mar.netMargin);

        ProfitSummaryController.PeriodRow feb = summary.months[1];
        Assert.areEqual(0, feb.netProfit);
        Assert.isNull(feb.netMargin, 'No sales, no margin');

        Assert.areEqual(520, summary.total.sales);
        Assert.areEqual(220, summary.total.grossProfit);
        Assert.areEqual(5060, summary.total.expenses);
        Assert.areEqual(-4840, summary.total.netProfit);

        Assert.areEqual(2, summary.expensesByCategory.size());
        Assert.areEqual('Rent', summary.expensesByCategory[0].category, 'Largest category first');
        Assert.areEqual(5000, summary.expensesByCategory[0].amount);
        Assert.areEqual('Staff Welfare', summary.expensesByCategory[1].category);
        Assert.areEqual(60, summary.expensesByCategory[1].amount);
    }

    @IsTest
    static void currentYearReportsCurrentMonth() {
        User admin = TestDataFactory.createUserWithPermissionSet('Nursery_Admin');
        ProfitSummaryController.Summary summary;
        System.runAs(admin) {
            summary = ProfitSummaryController.getSummary(null);
        }
        Assert.areEqual(Date.today().year(), summary.year);
        Assert.areEqual(Date.today().month(), summary.currentMonth);
        Assert.areEqual(0, summary.total.expenses, 'No entries this year');
    }

    @IsTest
    static void staffWithoutPermissionIsRefused() {
        User staff = TestDataFactory.createUserWithPermissionSet('Nursery_Staff');
        System.runAs(staff) {
            try {
                ProfitSummaryController.getSummary(YEAR);
                Assert.fail('Expected an AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('do not have access'), e.getMessage());
            }
        }
    }

    @IsTest
    static void rejectsYearOutOfRange() {
        User admin = TestDataFactory.createUserWithPermissionSet('Nursery_Admin');
        System.runAs(admin) {
            try {
                ProfitSummaryController.getSummary(Date.today().year() + 5);
                Assert.fail('Expected an AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().startsWith('Choose a year'), e.getMessage());
            }
        }
    }
}
