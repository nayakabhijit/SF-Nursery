import { LightningElement, api, wire } from 'lwc';
import { getRecords, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import CURRENCY from '@salesforce/i18n/currency';
import TIME_ZONE from '@salesforce/i18n/timeZone';

import createSales from '@salesforce/apex/PlantSaleController.createSales';

import STOCK_REMAINING from '@salesforce/schema/Plant__c.Stock_Remaining__c';
import AVG_PURCHASE_PRICE from '@salesforce/schema/Plant__c.Avg_Purchase_Price__c';

const PLANT_FIELDS = [STOCK_REMAINING, AVG_PURCHASE_PRICE];
const MAX_ROWS = 200;
/** Phone held upright: too narrow for the table, so rows are shown as stacked cards. */
const PORTRAIT_PHONE_QUERY = '(orientation: portrait) and (max-width: 767px)';

/** Today's date (YYYY-MM-DD) in the user's Salesforce time zone. */
function todayIso() {
    try {
        return new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE }).format(new Date());
    } catch (e) {
        return new Date().toISOString().slice(0, 10);
    }
}

function toNumber(value) {
    return value === '' || value === null || value === undefined ? null : Number(value);
}

/**
 * New Plant Sale form - enter several sales at once, one per row; "+ Add Sale" adds a row.
 * Each row shows the chosen plant's Current Stock and Avg. Purchase Cost (read-only, from
 * Plant__c) so staff can price the sale, and flags rows whose combined quantity for a plant
 * exceeds its stock. All rows are saved together (all-or-nothing) via PlantSaleController.
 *
 * Used two ways:
 *  - Quick action "New Sale" on a Plant record: recordId is the Plant, plant is fixed on every row.
 *  - "New" override on Plant Sale (via the plantSaleNewOverride Aura wrapper):
 *    plant is picked per row; defaultPlantId pre-fills it when opened from a Plant.
 */
export default class PlantSaleForm extends NavigationMixin(LightningElement) {
    /** Set by the quick action framework: the Plant record the action was launched from. */
    @api recordId;
    /** Set by the New override when opened from a Plant (related list "New"). */
    @api defaultPlantId;

    rows = [];
    saving = false;
    currencyCode = CURRENCY;
    maxDate = todayIso();

    /** getRecords config; only replaced when the set of plant ids changes. */
    plantRequest;
    plantsById = {};

    _nextKey = 0;
    _plantIdsSignature = '';
    _wiredPlants;
    _refreshedIds = new Set();

    /** True on a phone in portrait: show stacked cards and a "rotate" hint. */
    isPortraitPhone = false;
    rotateHintDismissed = false;
    _mediaQuery;
    _onMediaChange = (event) => {
        this.isPortraitPhone = event.matches;
    };

    connectedCallback() {
        if (!this.rows.length) {
            this.rows = [this.newRow()];
        }
        this.syncPlantRequest();
        this.watchOrientation();
    }

    disconnectedCallback() {
        if (this._mediaQuery) {
            if (this._mediaQuery.removeEventListener) {
                this._mediaQuery.removeEventListener('change', this._onMediaChange);
            } else {
                this._mediaQuery.removeListener(this._onMediaChange);
            }
            this._mediaQuery = null;
        }
    }

    // Pages cannot force the phone to rotate, so we follow the orientation the user picks.
    watchOrientation() {
        if (this._mediaQuery || typeof window === 'undefined' || !window.matchMedia) return;
        this._mediaQuery = window.matchMedia(PORTRAIT_PHONE_QUERY);
        this.isPortraitPhone = this._mediaQuery.matches;
        if (this._mediaQuery.addEventListener) {
            this._mediaQuery.addEventListener('change', this._onMediaChange);
        } else {
            this._mediaQuery.addListener(this._onMediaChange);
        }
    }

    get showRotateHint() {
        return this.isPortraitPhone && !this.rotateHintDismissed;
    }

    handleDismissRotateHint() {
        this.rotateHintDismissed = true;
    }

    renderedCallback() {
        // recordId (quick action) arrives after the first render.
        this.syncPlantRequest();
    }

    // ---------- Mode ----------

    get isQuickAction() {
        return !!this.recordId;
    }

    get containerClass() {
        return this.isQuickAction ? 'sale-form' : 'slds-card sale-form';
    }

    get bodyClass() {
        return this.isQuickAction ? 'slds-modal__content slds-p-around_medium' : 'slds-card__body slds-card__body_inner';
    }

    get footerClass() {
        return this.isQuickAction ? 'slds-modal__footer' : 'slds-card__footer slds-text-align_right';
    }

    // ---------- Rows ----------

    newRow(previous) {
        this._nextKey += 1;
        return {
            key: `row-${this._nextKey}`,
            saleDate: previous ? previous.saleDate : this.maxDate,
            plantId: previous ? previous.plantId : this.defaultPlantId || null,
            quantity: null,
            sellingPrice: null,
            notes: '',
            error: null
        };
    }

    rowPlantId(row) {
        return this.recordId || row.plantId;
    }

    get rowsView() {
        const usedByPlant = {};
        const single = this.rows.length === 1;
        return this.rows.map((row, index) => {
            const plantId = this.rowPlantId(row);
            const plant = plantId ? this.plantsById[plantId] : null;
            const quantity = toNumber(row.quantity) || 0;
            const price = toNumber(row.sellingPrice) || 0;

            let stock = null;
            let avgCost = null;
            let stockStatus = '';
            let exceedsStock = false;
            if (plant) {
                stock = getFieldValue(plant, STOCK_REMAINING) || 0;
                avgCost = getFieldValue(plant, AVG_PURCHASE_PRICE) || 0;
                if (stock < 0) stockStatus = '(oversold)';
                else if (stock === 0) stockStatus = '(out of stock)';
                // Rows for the same plant draw on the same stock.
                usedByPlant[plantId] = (usedByPlant[plantId] || 0) + quantity;
                exceedsStock = quantity > 0 && usedByPlant[plantId] > stock;
            }

            return {
                ...row,
                plantId,
                rowNumber: index + 1,
                errorKey: `${row.key}-error`,
                plantLoaded: !!plant,
                stock,
                avgCost,
                stockStatus,
                stockClass: plant && stock <= 0 ? 'slds-text-color_error' : '',
                exceedsStock,
                lineTotal: quantity * price,
                rowClass: row.error ? 'row-has-error' : '',
                removeDisabled: single || this.saving,
                removeLabel: `Remove row ${index + 1}`
            };
        });
    }

    get rowCount() {
        return this.rows.length;
    }

    get rowCountLabel() {
        return this.rows.length === 1 ? '1 sale' : `${this.rows.length} sales`;
    }

    get totalQuantity() {
        return this.rows.reduce((sum, r) => sum + (toNumber(r.quantity) || 0), 0);
    }

    get totalRevenue() {
        return this.rows.reduce(
            (sum, r) => sum + (toNumber(r.quantity) || 0) * (toNumber(r.sellingPrice) || 0),
            0
        );
    }

    get addDisabled() {
        return this.saving || this.rows.length >= MAX_ROWS;
    }

    get saveLabel() {
        return this.rows.length > 1 ? `Save ${this.rows.length} Sales` : 'Save';
    }

    handleAddRow() {
        if (this.rows.length >= MAX_ROWS) return;
        const last = this.rows[this.rows.length - 1];
        this.rows = [...this.rows, this.newRow(last)];
        this.syncPlantRequest();
    }

    handleRemoveRow(event) {
        const key = event.currentTarget.dataset.key;
        if (this.rows.length === 1) return;
        this.rows = this.rows.filter((r) => r.key !== key);
        this.syncPlantRequest();
    }

    handleFieldChange(event) {
        const { key, field } = event.target.dataset;
        this.updateRow(key, { [field]: event.detail.value });
    }

    handlePlantChange(event) {
        const key = event.target.dataset.key;
        this.updateRow(key, { plantId: event.detail.recordId || null });
        this.syncPlantRequest();
    }

    updateRow(key, changes) {
        this.rows = this.rows.map((r) => (r.key === key ? { ...r, ...changes, error: null } : r));
    }

    // ---------- Plant stock / cost ----------

    syncPlantRequest() {
        const ids = [...new Set(this.rows.map((r) => this.rowPlantId(r)).filter(Boolean))].sort();
        const signature = ids.join(',');
        if (signature === this._plantIdsSignature) return;
        this._plantIdsSignature = signature;
        this.plantRequest = ids.length ? [{ recordIds: ids, fields: PLANT_FIELDS }] : undefined;
    }

    @wire(getRecords, { records: '$plantRequest' })
    wiredPlants(result) {
        this._wiredPlants = result;
        const { data } = result;
        if (!data) return;

        const byId = { ...this.plantsById };
        let needsRefresh = false;
        data.results.forEach((item) => {
            if (item.statusCode === 200 && item.result) {
                byId[item.result.id] = item.result;
                if (!this._refreshedIds.has(item.result.id)) {
                    this._refreshedIds.add(item.result.id);
                    needsRefresh = true;
                }
            }
        });
        this.plantsById = byId;

        // Cached values may be stale (another sale/purchase since); fetch fresh once per plant.
        if (needsRefresh) {
            refreshApex(this._wiredPlants);
        }
    }

    // ---------- Save ----------

    validate() {
        const inputs = [...this.template.querySelectorAll('lightning-input, lightning-record-picker')];
        return inputs.reduce((ok, input) => (input.disabled || input.reportValidity()) && ok, true);
    }

    async handleSave() {
        if (this.saving || !this.validate()) return;

        const sales = this.rows.map((r) => ({
            sobjectType: 'Plant_Sale__c',
            Plant__c: this.rowPlantId(r),
            Sale_Date__c: r.saleDate,
            Quantity_Sold__c: toNumber(r.quantity),
            Selling_Price__c: toNumber(r.sellingPrice),
            Notes__c: r.notes || null
        }));

        this.saving = true;
        try {
            const result = await createSales({ sales });
            if (result.errors && result.errors.length) {
                this.showRowErrors(result.errors);
                return;
            }
            await this.afterSave(result.saleIds, sales);
        } catch (error) {
            this.toast('Sales not saved', this.errorMessage(error), 'error');
        } finally {
            this.saving = false;
        }
    }

    showRowErrors(errors) {
        const byIndex = {};
        errors.forEach((e) => {
            byIndex[e.rowIndex] = e.message;
        });
        this.rows = this.rows.map((r, i) => ({ ...r, error: byIndex[i] || null }));
        const count = errors.length;
        this.toast(
            'Sales not saved',
            `${count} ${count === 1 ? 'row has' : 'rows have'} errors. Nothing was saved - fix the highlighted ${
                count === 1 ? 'row' : 'rows'
            } and save again.`,
            'error'
        );
    }

    async afterSave(saleIds, sales) {
        const count = saleIds.length;
        this.toast(
            count === 1 ? 'Sale saved' : 'Sales saved',
            count === 1 ? '1 Plant Sale was created.' : `${count} Plant Sales were created.`,
            'success'
        );

        // Stock and roll-ups on the Plants changed on the server; refresh any open views.
        const plantIds = [...new Set(sales.map((s) => s.Plant__c).filter(Boolean))];
        if (plantIds.length) {
            try {
                await notifyRecordUpdateAvailable(plantIds.map((recordId) => ({ recordId })));
            } catch (e) {
                // non-fatal
            }
        }

        if (this.isQuickAction) {
            this.dispatchEvent(new CloseActionScreenEvent());
        } else if (count === 1) {
            this.navigateToRecord(saleIds[0], 'Plant_Sale__c');
        } else {
            this.navigateBack();
        }
    }

    handleCancel() {
        if (this.isQuickAction) {
            this.dispatchEvent(new CloseActionScreenEvent());
        } else {
            this.navigateBack();
        }
    }

    navigateBack() {
        if (this.defaultPlantId) {
            this.navigateToRecord(this.defaultPlantId, 'Plant__c');
        } else {
            this[NavigationMixin.Navigate]({
                type: 'standard__objectPage',
                attributes: { objectApiName: 'Plant_Sale__c', actionName: 'list' },
                state: { filterName: 'Recent' }
            });
        }
    }

    navigateToRecord(recordId, objectApiName) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, objectApiName, actionName: 'view' }
        });
    }

    // ---------- Helpers ----------

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    errorMessage(error) {
        if (!error) return 'Unknown error.';
        if (error.body) {
            if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(' ');
            if (error.body.message) return error.body.message;
        }
        return error.message || 'Unknown error.';
    }
}
