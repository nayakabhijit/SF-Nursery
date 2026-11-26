import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import CURRENCY from '@salesforce/i18n/currency';
import LOCALE from '@salesforce/i18n/locale';

import getSummary from '@salesforce/apex/ProfitSummaryController.getSummary';

const THIS_YEAR = new Date().getFullYear();

/**
 * Profit & Loss summary for the Nursery Home page.
 * Net Profit = Gross Profit on plant sales (Sales - Cost of Plants Sold) - Expenses.
 * Figures come from ProfitSummaryController.getSummary for the chosen calendar year.
 */
export default class ProfitSummary extends LightningElement {
    year = THIS_YEAR;
    summary;
    error;
    loading = true;

    _wired;
    _money = new Intl.NumberFormat(LOCALE, {
        style: 'currency',
        currency: CURRENCY,
        maximumFractionDigits: 0
    });
    _percent = new Intl.NumberFormat(LOCALE, { style: 'percent', maximumFractionDigits: 1 });

    @wire(getSummary, { year: '$year' })
    wiredSummary(result) {
        this._wired = result;
        this.loading = false;
        if (result.data) {
            this.summary = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.summary = undefined;
            this.error = reduceError(result.error);
        }
    }

    get yearOptions() {
        const first = Math.min(this.summary?.firstYear ?? THIS_YEAR, this.year);
        const options = [];
        for (let y = THIS_YEAR; y >= first; y--) {
            options.push({ label: String(y), value: String(y) });
        }
        return options;
    }

    get yearValue() {
        return String(this.year);
    }

    get hasData() {
        return !!this.summary;
    }

    get periodLabel() {
        return this.year === THIS_YEAR ? `${this.year} to date` : String(this.year);
    }

    /** KPI tiles for the year. */
    get tiles() {
        const t = this.summary?.total;
        if (!t) return [];
        return [
            { key: 'sales', label: 'Sales', value: this.money(t.sales), css: 'tile' },
            {
                key: 'gross',
                label: 'Gross Profit',
                sub: 'Sales − cost of plants sold',
                value: this.money(t.grossProfit),
                css: 'tile'
            },
            {
                key: 'expenses',
                label: 'Expenses',
                value: this.money(t.expenses),
                css: 'tile tile_expense'
            },
            {
                key: 'net',
                label: 'Net Profit',
                sub: 'Gross profit − expenses',
                value: this.money(t.netProfit),
                css: `tile tile_net ${t.netProfit < 0 ? 'is-loss' : 'is-profit'}`
            },
            {
                key: 'margin',
                label: 'Net Margin',
                sub: 'Net profit ÷ sales',
                value: t.netMargin === null || t.netMargin === undefined ? '—' : this._percent.format(t.netMargin),
                css: `tile ${t.netProfit < 0 ? 'is-loss' : ''}`
            }
        ];
    }

    /** Current month (when viewing this year), shown as a highlighted strip. */
    get thisMonth() {
        const s = this.summary;
        if (!s || !s.currentMonth) return null;
        const m = s.months[s.currentMonth - 1];
        return {
            label: `${m.label} ${s.year}`,
            sales: this.money(m.sales),
            gross: this.money(m.grossProfit),
            expenses: this.money(m.expenses),
            net: this.money(m.netProfit),
            netCss: m.netProfit < 0 ? 'value is-loss' : 'value is-profit'
        };
    }

    /** Month rows (up to the current month for this year), with a bar scaled to the largest |net|. */
    get rows() {
        const s = this.summary;
        if (!s) return [];
        const months = s.currentMonth ? s.months.slice(0, s.currentMonth) : s.months;
        const maxAbs = Math.max(1, ...months.map((m) => Math.abs(m.netProfit)));
        return months.map((m) => {
            const loss = m.netProfit < 0;
            const width = Math.round((Math.abs(m.netProfit) / maxAbs) * 100);
            return {
                key: m.month,
                label: m.label,
                rowCss: m.month === s.currentMonth ? 'is-current' : '',
                sales: this.money(m.sales),
                cost: this.money(m.costOfPlantsSold),
                gross: this.money(m.grossProfit),
                expenses: this.money(m.expenses),
                net: this.money(m.netProfit),
                netCss: `slds-text-align_right num ${loss ? 'is-loss' : ''}`,
                margin:
                    m.netMargin === null || m.netMargin === undefined ? '—' : this._percent.format(m.netMargin),
                barCss: `bar ${loss ? 'bar_loss' : 'bar_profit'}`,
                barStyle: `width:${width}%`
            };
        });
    }

    get total() {
        const t = this.summary?.total;
        if (!t) return null;
        return {
            sales: this.money(t.sales),
            cost: this.money(t.costOfPlantsSold),
            gross: this.money(t.grossProfit),
            expenses: this.money(t.expenses),
            net: this.money(t.netProfit),
            netCss: `slds-text-align_right num ${t.netProfit < 0 ? 'is-loss' : ''}`,
            margin: t.netMargin === null || t.netMargin === undefined ? '—' : this._percent.format(t.netMargin)
        };
    }

    get categories() {
        const list = this.summary?.expensesByCategory ?? [];
        return list.map((c) => ({
            key: c.category,
            label: c.category,
            amount: this.money(c.amount),
            share: this._percent.format(c.share),
            barStyle: `width:${Math.round(c.share * 100)}%`
        }));
    }

    get hasCategories() {
        return this.categories.length > 0;
    }

    money(value) {
        return this._money.format(value ?? 0);
    }

    handleYearChange(event) {
        this.loading = true;
        this.year = Number(event.detail.value);
    }

    async handleRefresh() {
        this.loading = true;
        try {
            await refreshApex(this._wired);
        } finally {
            this.loading = false;
        }
    }
}

function reduceError(error) {
    if (Array.isArray(error?.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error?.body?.message || error?.message || 'Could not load the profit summary.';
}
