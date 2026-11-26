/**
 * Plant_Sale__c trigger. All logic lives in PlantSaleTriggerHandler.
 * After delete / after undelete are wired for future use (roll-ups already handle stock).
 */
trigger PlantSaleTrigger on Plant_Sale__c(before insert, before update, after delete, after undelete) {
    switch on Trigger.operationType {
        when BEFORE_INSERT {
            PlantSaleTriggerHandler.beforeInsert(Trigger.new);
        }
        when BEFORE_UPDATE {
            PlantSaleTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
        }
        when AFTER_DELETE {
            PlantSaleTriggerHandler.afterDelete(Trigger.old);
        }
        when AFTER_UNDELETE {
            PlantSaleTriggerHandler.afterUndelete(Trigger.new);
        }
    }
}
