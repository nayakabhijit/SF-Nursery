/**
 * Logic for ExpenseEntryTrigger.
 *  - Blocks new entries for an inactive Expense.
 *  - Monthly expenses: moves Expense Date to the 1st of its month, and allows only one
 *    entry per Expense per calendar month (checked within the batch and against saved
 *    entries). Daily expenses can have any number of entries per day.
 *
 * Expenses and existing entries are read WITH SYSTEM_MODE so the checks see every
 * record, whatever the running user can see.
 */
public with sharing class ExpenseEntryTriggerHandler {
    public static final String TYPE_MONTHLY = 'Monthly';

    public static void beforeInsert(List<Expense_Entry__c> newEntries) {
        Map<Id, Expense__c> expensesById = loadExpenses(newEntries);
        for (Expense_Entry__c entry : newEntries) {
            Expense__c expense = expensesById.get(entry.Expense__c);
            if (expense != null && !expense.Active__c) {
                entry.addError(
                    expense.Name + ' is inactive. Tick Active on the expense before adding entries to it.'
                );
            }
        }
        applyMonthlyRules(newEntries, expensesById);
    }

    public static void beforeUpdate(List<Expense_Entry__c> newEntries) {
        applyMonthlyRules(newEntries, loadExpenses(newEntries));
    }

    private static Map<Id, Expense__c> loadExpenses(List<Expense_Entry__c> entries) {
        Set<Id> expenseIds = new Set<Id>();
        for (Expense_Entry__c entry : entries) {
            if (entry.Expense__c != null) {
                expenseIds.add(entry.Expense__c);
            }
        }
        if (expenseIds.isEmpty()) {
            return new Map<Id, Expense__c>();
        }
        return new Map<Id, Expense__c>(
            [SELECT Id, Name, Expense_Type__c, Active__c FROM Expense__c WHERE Id IN :expenseIds WITH SYSTEM_MODE]
        );
    }

    private static void applyMonthlyRules(List<Expense_Entry__c> entries, Map<Id, Expense__c> expensesById) {
        List<Expense_Entry__c> monthlyEntries = new List<Expense_Entry__c>();
        Set<Id> monthlyExpenseIds = new Set<Id>();
        Set<Id> entryIds = new Set<Id>();
        Date earliest;
        Date latest;

        for (Expense_Entry__c entry : entries) {
            Expense__c expense = expensesById.get(entry.Expense__c);
            if (expense == null || expense.Expense_Type__c != TYPE_MONTHLY || entry.Expense_Date__c == null) {
                continue;
            }
            entry.Expense_Date__c = entry.Expense_Date__c.toStartOfMonth();
            monthlyEntries.add(entry);
            monthlyExpenseIds.add(expense.Id);
            if (entry.Id != null) {
                entryIds.add(entry.Id);
            }
            earliest = (earliest == null || entry.Expense_Date__c < earliest) ? entry.Expense_Date__c : earliest;
            latest = (latest == null || entry.Expense_Date__c > latest) ? entry.Expense_Date__c : latest;
        }
        if (monthlyEntries.isEmpty()) {
            return;
        }

        // Saved entries in the same months. Matched by month (not exact date) so entries
        // saved before an expense was switched from Daily to Monthly are counted too.
        Date rangeEnd = latest.addMonths(1);
        Map<String, Expense_Entry__c> takenByKey = new Map<String, Expense_Entry__c>();
        for (Expense_Entry__c existing : [
            SELECT Id, Name, Expense__c, Expense_Date__c
            FROM Expense_Entry__c
            WHERE Expense__c IN :monthlyExpenseIds
                AND Expense_Date__c >= :earliest
                AND Expense_Date__c < :rangeEnd
                AND Id NOT IN :entryIds
            WITH SYSTEM_MODE
        ]) {
            takenByKey.put(monthKey(existing.Expense__c, existing.Expense_Date__c), existing);
        }

        for (Expense_Entry__c entry : monthlyEntries) {
            String key = monthKey(entry.Expense__c, entry.Expense_Date__c);
            Expense_Entry__c taken = takenByKey.get(key);
            if (taken != null) {
                String clash = taken.Name == null ? 'another row in this save' : taken.Name;
                entry.Expense_Date__c.addError(
                    expensesById.get(entry.Expense__c).Name + ' is a Monthly expense and already has an entry for ' +
                    monthLabel(entry.Expense_Date__c) + ' (' + clash + '). Edit that entry instead.'
                );
            } else {
                takenByKey.put(key, entry);
            }
        }
    }

    private static String monthKey(Id expenseId, Date day) {
        return expenseId + '|' + day.year() + '-' + day.month();
    }

    private static String monthLabel(Date day) {
        return Datetime.newInstance(day.year(), day.month(), 1).format('MMMM yyyy');
    }
}
