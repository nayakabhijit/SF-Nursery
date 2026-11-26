/**
 * Server side of the multi-row New Plant Sale form (plantSaleForm LWC).
 *
 * createSales inserts all rows in one DML so PlantSaleTrigger sees them as one batch:
 * the oversell check then counts every row for the same plant together. Saving is
 * all-or-nothing - if any row fails, nothing is saved and each failing row's errors
 * are returned by row index so the form can show them next to the row.
 *
 * DML runs in USER_MODE: the user's object and field permissions apply.
 */
public with sharing class PlantSaleController {
    public static final Integer MAX_ROWS = 200;

    public class SaveResult {
        @AuraEnabled
        public List<Id> saleIds = new List<Id>();
        @AuraEnabled
        public List<RowError> errors = new List<RowError>();
    }

    public class RowError {
        @AuraEnabled
        public Integer rowIndex;
        @AuraEnabled
        public String message;

        RowError(Integer rowIndex, String message) {
            this.rowIndex = rowIndex;
            this.message = message;
        }
    }

    @AuraEnabled
    public static SaveResult createSales(List<Plant_Sale__c> sales) {
        if (sales == null || sales.isEmpty()) {
            throw newAuraException('Add at least one sale.');
        }
        if (sales.size() > MAX_ROWS) {
            throw newAuraException('You can save up to ' + MAX_ROWS + ' sales at a time.');
        }

        // Copy only the fields the form edits; ignore anything else the client sends.
        List<Plant_Sale__c> toInsert = new List<Plant_Sale__c>();
        for (Plant_Sale__c sale : sales) {
            toInsert.add(
                new Plant_Sale__c(
                    Plant__c = sale.Plant__c,
                    Sale_Date__c = sale.Sale_Date__c,
                    Quantity_Sold__c = sale.Quantity_Sold__c,
                    Selling_Price__c = sale.Selling_Price__c,
                    Notes__c = sale.Notes__c
                )
            );
        }

        SaveResult outcome = new SaveResult();
        Savepoint sp = Database.setSavepoint();
        try {
            // allOrNone = false collects every row's errors in one pass; we roll back below
            // if any row failed so the save stays all-or-nothing.
            List<Database.SaveResult> results = Database.insert(toInsert, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    outcome.saleIds.add(results[i].getId());
                } else {
                    outcome.errors.add(new RowError(i, joinMessages(results[i].getErrors())));
                }
            }
        } catch (Exception e) {
            Database.rollback(sp);
            throw newAuraException(e.getMessage());
        }

        if (!outcome.errors.isEmpty()) {
            Database.rollback(sp);
            outcome.saleIds.clear();
        }
        return outcome;
    }

    private static String joinMessages(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error err : errors) {
            messages.add(err.getMessage());
        }
        return String.join(messages, ' ');
    }

    private static AuraHandledException newAuraException(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
