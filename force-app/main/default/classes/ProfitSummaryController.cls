/**
 * Server side of the Profit & Loss summary (profitSummary LWC) on the Nursery Home page.
 *
 * For a calendar year, per month:
 *   Sales            = SUM(Plant_Sale__c.Sale_Revenue__c)
 *   Cost of Plants   = SUM(Plant_Sale__c.Cost_of_Plants_Sold__c)
 *   Gross Profit     = SUM(Plant_Sale__c.Gross_Profit__c)
 *   Expenses         = SUM(Expense_Entry__c.Amount__c)
 *   Net Profit       = Gross Profit - Expenses
 * plus expenses by category for the year.
 *
 * Sales are summed in Apex because Sale_Revenue__c and Gross_Profit__c are formula fields,
 * which SOQL cannot SUM. Queries run WITH USER_MODE, so the user's object and field access
 * applies. Requires the View_Profit_and_Loss custom permission (Nursery Admin).
 */
public with sharing class ProfitSummaryController {
    public static final String VIEW_PERMISSION = 'View_Profit_and_Loss';
    private static final List<String> MONTH_LABELS = new List<String>{
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    };

    public class Summary {
        @AuraEnabled
        public Integer year;
        /** Month number (1-12) of today if year is the current year, otherwise null. */
        @AuraEnabled
        public Integer currentMonth;
        /** Earliest year with a sale or expense entry (for the year picker). */
        @AuraEnabled
        public Integer firstYear;
        @AuraEnabled
        public List<PeriodRow> months = new List<PeriodRow>();
        @AuraEnabled
        public PeriodRow total;
        @AuraEnabled
        public List<CategoryRow> expensesByCategory = new List<CategoryRow>();
    }

    public class PeriodRow {
        @AuraEnabled
        public Integer month;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Decimal sales = 0;
        @AuraEnabled
        public Decimal costOfPlantsSold = 0;
        @AuraEnabled
        public Decimal grossProfit = 0;
        @AuraEnabled
        public Decimal expenses = 0;
        @AuraEnabled
        public Decimal netProfit = 0;
        /** Net Profit / Sales as a fraction (0.25 = 25%); null when there are no sales. */
        @AuraEnabled
        public Decimal netMargin;

        PeriodRow(Integer month, String label) {
            this.month = month;
            this.label = label;
        }

        void finish() {
            netProfit = grossProfit - expenses;
            netMargin = sales == 0 ? null : (netProfit / sales).setScale(4);
        }
    }

    public class CategoryRow {
        @AuraEnabled
        public String category;
        @AuraEnabled
        public Decimal amount;
        /** Share of the year's expenses as a fraction. */
        @AuraEnabled
        public Decimal share;

        CategoryRow(String category, Decimal amount) {
            this.category = category;
            this.amount = amount;
        }
    }

    @AuraEnabled(cacheable=true)
    public static Summary getSummary(Integer year) {
        if (!FeatureManagement.checkPermission(VIEW_PERMISSION)) {
            throw newAuraException('You do not have access to Profit & Loss figures. Ask your administrator for the Nursery Admin permission set.');
        }
        Integer today = Date.today().year();
        Integer y = year == null ? today : year;
        if (y < 1900 || y > today + 1) {
            throw newAuraException('Choose a year between 1900 and ' + (today + 1) + '.');
        }

        Summary result = new Summary();
        result.year = y;
        result.currentMonth = y == today ? Date.today().month() : null;
        result.total = new PeriodRow(null, 'Total');
        for (Integer m = 1; m <= 12; m++) {
            result.months.add(new PeriodRow(m, MONTH_LABELS[m - 1]));
        }

        Date startDate = Date.newInstance(y, 1, 1);
        Date endDate = Date.newInstance(y + 1, 1, 1);

        for (Plant_Sale__c sale : [
            SELECT Sale_Date__c, Sale_Revenue__c, Cost_of_Plants_Sold__c, Gross_Profit__c
            FROM Plant_Sale__c
            WHERE Sale_Date__c >= :startDate AND Sale_Date__c < :endDate
            WITH USER_MODE
        ]) {
            PeriodRow row = result.months[sale.Sale_Date__c.month() - 1];
            row.sales += nz(sale.Sale_Revenue__c);
            row.costOfPlantsSold += nz(sale.Cost_of_Plants_Sold__c);
            row.grossProfit += nz(sale.Gross_Profit__c);
        }

        Map<String, Decimal> byCategory = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT CALENDAR_MONTH(Expense_Date__c) mon, Expense__r.Category__c cat, SUM(Amount__c) amt
            FROM Expense_Entry__c
            WHERE Expense_Date__c >= :startDate AND Expense_Date__c < :endDate
            WITH USER_MODE
            GROUP BY CALENDAR_MONTH(Expense_Date__c), Expense__r.Category__c
        ]) {
            Decimal amount = nz((Decimal) ar.get('amt'));
            result.months[(Integer) ar.get('mon') - 1].expenses += amount;
            String category = (String) ar.get('cat');
            category = String.isBlank(category) ? 'Uncategorised' : category;
            byCategory.put(category, nz(byCategory.get(category)) + amount);
        }

        PeriodRow total = result.total;
        for (PeriodRow row : result.months) {
            row.finish();
            total.sales += row.sales;
            total.costOfPlantsSold += row.costOfPlantsSold;
            total.grossProfit += row.grossProfit;
            total.expenses += row.expenses;
        }
        total.finish();

        for (String category : byCategory.keySet()) {
            CategoryRow catRow = new CategoryRow(category, byCategory.get(category));
            catRow.share = total.expenses == 0 ? 0 : (catRow.amount / total.expenses).setScale(4);
            result.expensesByCategory.add(catRow);
        }
        sortByAmountDescending(result.expensesByCategory);

        result.firstYear = firstYear(today);
        return result;
    }

    private static Integer firstYear(Integer fallback) {
        Integer first = fallback;
        AggregateResult sales = [SELECT MIN(Sale_Date__c) d FROM Plant_Sale__c WITH USER_MODE];
        AggregateResult expenses = [SELECT MIN(Expense_Date__c) d FROM Expense_Entry__c WITH USER_MODE];
        for (AggregateResult ar : new List<AggregateResult>{ sales, expenses }) {
            Date d = (Date) ar.get('d');
            if (d != null && d.year() < first) {
                first = d.year();
            }
        }
        return first;
    }

    private static void sortByAmountDescending(List<CategoryRow> rows) {
        // Insertion sort: at most one row per category (about 10).
        for (Integer i = 1; i < rows.size(); i++) {
            CategoryRow current = rows[i];
            Integer j = i - 1;
            while (j >= 0 && rows[j].amount < current.amount) {
                rows[j + 1] = rows[j];
                j--;
            }
            rows[j + 1] = current;
        }
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    private static AuraHandledException newAuraException(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
