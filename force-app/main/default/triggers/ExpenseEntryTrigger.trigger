/**
 * Expense_Entry__c trigger. All logic lives in ExpenseEntryTriggerHandler.
 */
trigger ExpenseEntryTrigger on Expense_Entry__c(before insert, before update) {
    switch on Trigger.operationType {
        when BEFORE_INSERT {
            ExpenseEntryTriggerHandler.beforeInsert(Trigger.new);
        }
        when BEFORE_UPDATE {
            ExpenseEntryTriggerHandler.beforeUpdate(Trigger.new);
        }
    }
}
