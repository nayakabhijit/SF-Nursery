/**
 * Logic for PlantTrigger.
 *  - Normalises Plant Name (trims and collapses extra spaces).
 *  - Sets Plant_Key__c = normalised name in lower case.
 *  - Blocks duplicate plant names with a friendly error (the unique Plant_Key__c
 *    index is the final safety net).
 * Queries use WITH SYSTEM_MODE (API 67+ defaults to user mode) so the duplicate check
 * works for every user; record sharing still follows the class's "with sharing".
 */
public with sharing class PlantTriggerHandler {
    public static void beforeInsert(List<Plant__c> newPlants) {
        normaliseAndCheckDuplicates(newPlants);
    }

    public static void beforeUpdate(List<Plant__c> newPlants, Map<Id, Plant__c> oldMap) {
        normaliseAndCheckDuplicates(newPlants);
    }

    /** Trimmed name with internal runs of whitespace collapsed to one space. */
    public static String normaliseName(String name) {
        return String.isBlank(name) ? name : name.normalizeSpace();
    }

    /** Key used for duplicate detection and data-import upserts. */
    public static String toKey(String name) {
        return String.isBlank(name) ? null : name.normalizeSpace().toLowerCase();
    }

    private static void normaliseAndCheckDuplicates(List<Plant__c> plants) {
        Map<String, Plant__c> plantsByKey = new Map<String, Plant__c>();

        for (Plant__c plant : plants) {
            plant.Name = normaliseName(plant.Name);
            plant.Plant_Key__c = toKey(plant.Name);
            if (plant.Plant_Key__c == null) {
                continue;
            }
            if (plantsByKey.containsKey(plant.Plant_Key__c)) {
                plant.Name.addError(duplicateMessage(plant.Name));
            } else {
                plantsByKey.put(plant.Plant_Key__c, plant);
            }
        }

        if (plantsByKey.isEmpty()) {
            return;
        }

        for (Plant__c existing : [
            SELECT Id, Name, Plant_Key__c
            FROM Plant__c
            WHERE Plant_Key__c IN :plantsByKey.keySet()
            WITH SYSTEM_MODE
        ]) {
            Plant__c incoming = plantsByKey.get(existing.Plant_Key__c.toLowerCase());
            if (incoming != null && incoming.Id != existing.Id) {
                incoming.Name.addError(duplicateMessage(existing.Name));
            }
        }
    }

    private static String duplicateMessage(String name) {
        return 'Plant ' + name + ' already exists.';
    }
}
