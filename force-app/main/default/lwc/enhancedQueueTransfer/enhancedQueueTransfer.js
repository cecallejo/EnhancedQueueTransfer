import { api, LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import getTransferQueues from '@salesforce/apex/EnhancedQueueTransferController.getTransferQueues';
import getQueueMetrics from '@salesforce/apex/EnhancedQueueTransferController.getQueueMetrics';
import getQueueMetricsByNames from '@salesforce/apex/EnhancedQueueTransferController.getQueueMetricsByNames';
import transferRecordToQueue from '@salesforce/apex/EnhancedQueueTransferController.transferRecordToQueue';

export default class EnhancedQueueTransfer extends LightningElement {
    @api recordId;
    @api objectApiName;

    isLoading = false;
    processingQueueId;
    allQueues = [];
    queues = [];
    errorMessage;
    searchTerm = '';
    searchDebounceId;
    refreshTimeoutId;
    isDisconnected = false;
    _sessionStatus; // populated reactively by @wire(getRecord)
    static AUTO_REFRESH_MS = 10000;

    // Observa o Status do MessagingSession em tempo real via uiRecordApi.
    // Quando o status muda, re-enriquece as linhas sem precisar de Apex polling.
    @wire(getRecord, { recordId: '$recordId', fields: ['MessagingSession.Status'] })
    handleSessionRecord({ data }) {
        if (!data) return;
        const newStatus = getFieldValue(data, 'MessagingSession.Status');
        if (newStatus !== this._sessionStatus) {
            this._sessionStatus = newStatus;
            if (this.allQueues.length) {
                this.allQueues = this.allQueues.map((row) =>
                    this.enrichQueueRow({ ...row, canTransfer: this.transferAllowed })
                );
                this.applySearchFilter();
            }
        }
    }

    get transferAllowed() {
        if (this.objectApiName !== 'MessagingSession') return true;
        // Otimista enquanto o wire ainda não resolveu (evita cinza no carregamento inicial)
        if (this._sessionStatus === undefined) return true;
        return this._sessionStatus === 'Active';
    }

    connectedCallback() {
        this.isDisconnected = false;
        this.loadQueues();
    }

    disconnectedCallback() {
        this.isDisconnected = true;
        this.stopAutoRefresh();
    }

    get hasQueues() {
        return this.queues.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && !this.errorMessage && !this.hasQueues;
    }

    async loadQueues() {
        if (this.isLoading) {
            return;
        }
        this.stopAutoRefresh();
        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const nativeResult = await this.fetchNativeTransferQueues();
            const nativeQueues = nativeResult.normalizedQueues;
            let baseQueues = nativeQueues;
            let source = 'nativeBridge';

            // Fallback only when native transfer list is unavailable.
            if (!baseQueues.length) {
                const apexRows = await getTransferQueues({
                    objectApiName: this.objectApiName,
                    searchTerm: null
                });
                baseQueues = (apexRows || []).map((row) => ({
                    queueId: row.queueId,
                    queueName: row.queueName
                }));
                source = 'apexFallback';
            }

            if (!baseQueues.length) {
                this.allQueues = [];
                this.queues = [];
                return;
            }

            const [metricsByNames, metricsByIds] = await Promise.all([
                getQueueMetricsByNames({
                    queueNames: baseQueues.map((row) => row.queueName)
                }),
                getQueueMetrics({
                    queueIds: baseQueues.map((row) => row.queueId)
                })
            ]);
            this.allQueues = this.mergeQueueMetrics(baseQueues, metricsByNames, metricsByIds);
            this.applySearchFilter();
        } catch (error) {
            this.errorMessage = this.extractError(error);
            this.allQueues = [];
            this.queues = [];
        } finally {
            this.isLoading = false;
            this.scheduleNextRefresh();
        }
    }

    async refreshMetricsOnly() {
        if (this.isLoading || this.processingQueueId || !this.allQueues.length) {
            this.scheduleNextRefresh();
            return;
        }

        try {
            const [metricsByNames, metricsByIds] = await Promise.all([
                getQueueMetricsByNames({
                    queueNames: this.allQueues.map((row) => row.queueName)
                }),
                getQueueMetrics({
                    queueIds: this.allQueues.map((row) => row.queueId)
                })
            ]);
            this.allQueues = this.mergeQueueMetrics(this.allQueues, metricsByNames, metricsByIds);
            this.applySearchFilter();
        } catch (_error) {
            // Mantém UI estável se o refresh de métricas falhar transitoriamente.
        } finally {
            this.scheduleNextRefresh();
        }
    }

    handleManualRefresh() {
        this.loadQueues();
    }

    mergeQueueMetrics(baseQueues, metricsByNames, metricsByIds) {
        const metricsByQueueName = new Map(
            (metricsByNames || []).map((row) => [this.normalizeKey(row.queueName), row])
        );
        const metricsByQueueId = new Map((metricsByIds || []).map((row) => [row.queueId, row]));

        return (baseQueues || []).map((base) => {
            const metricById = metricsByQueueId.get(base.queueId) || {};
            const metricByName = metricsByQueueName.get(this.normalizeKey(base.queueName)) || {};
            const usedName = metricById.queueName || base.queueName;
            const waitingCount =
                metricById.waitingCount !== undefined
                    ? metricById.waitingCount
                    : metricByName.waitingCount;
            const ewtMinutes =
                metricById.ewtMinutes !== undefined
                    ? metricById.ewtMinutes
                    : metricByName.ewtMinutes;
            return this.enrichQueueRow({
                queueId: base.queueId,
                queueName: usedName,
                waitingCount,
                ewtMinutes,
                canTransfer: this.transferAllowed
            });
        });
    }

    scheduleNextRefresh() {
        if (this.isDisconnected) {
            return;
        }
        this.stopAutoRefresh();
        this.refreshTimeoutId = window.setTimeout(() => {
            this.refreshMetricsOnly();
        }, EnhancedQueueTransfer.AUTO_REFRESH_MS);
    }

    stopAutoRefresh() {
        if (this.refreshTimeoutId) {
            window.clearTimeout(this.refreshTimeoutId);
            this.refreshTimeoutId = undefined;
        }
    }

    handleSearchChange(event) {
        this.searchTerm = (event.target.value || '').trim();
        window.clearTimeout(this.searchDebounceId);
        this.searchDebounceId = window.setTimeout(() => {
            this.applySearchFilter();
            this.scheduleNextRefresh();
        }, 250);
    }

    async fetchNativeTransferQueues() {
        const omniBridge = window?.enhancedQueueTransferOmniBridge;
        if (!omniBridge) {
            return {
                rawRows: [],
                normalizedQueues: []
            };
        }

        const nativeListMethod =
            omniBridge.getTransferQueues ||
            omniBridge.getAvailableTransferQueues ||
            omniBridge.listTransferQueues;

        if (typeof nativeListMethod !== 'function') {
            return {
                rawRows: [],
                normalizedQueues: []
            };
        }

        const nativeRows = await nativeListMethod({
            recordId: this.recordId,
            objectApiName: this.objectApiName
        });

        const normalizedQueues = (nativeRows || [])
            .map((row) => this.normalizeNativeQueue(row))
            .filter((row) => row.queueId && row.queueName);
        return {
            rawRows: nativeRows || [],
            normalizedQueues
        };
    }

    normalizeNativeQueue(row) {
        const queueId =
            row?.queueId ||
            row?.destinationQueueId ||
            row?.targetQueueId ||
            row?.queue?.id ||
            row?.queue?.queueId;
        if (!this.isQueueId(queueId)) {
            return {
                queueId: null,
                queueName: null
            };
        }

        return {
            queueId,
            queueName: row?.queueName || row?.queue?.name || row?.name || row?.label
        };
    }

    normalizeKey(value) {
        return (value || '').toLowerCase().trim();
    }

    isQueueId(value) {
        return typeof value === 'string' && value.startsWith('00G');
    }

    applySearchFilter() {
        const term = this.searchTerm?.toLowerCase();
        if (!term) {
            this.queues = [...this.allQueues];
            return;
        }

        this.queues = this.allQueues.filter((row) =>
            (row.queueName || '').toLowerCase().includes(term)
        );
    }

    enrichQueueRow(row) {
        const ewt = row.ewtMinutes;
        const disabled = !row.canTransfer || this.processingQueueId === row.queueId;
        return {
            ...row,
            waitingDisplay: row.waitingCount ?? '--',
            ewtDisplay: ewt ?? '--',
            ewtBadgeClass: this.resolveEwtBadgeClass(ewt),
            isProcessing: this.processingQueueId === row.queueId,
            isTransferDisabled: disabled,
            // 'brand' = azul preenchido; 'border-filled' + disabled = cinza nativo do SLDS
            transferButtonVariant: disabled ? 'border-filled' : 'brand'
        };
    }

    resolveEwtBadgeClass(ewtMinutes) {
        if (ewtMinutes === null || ewtMinutes === undefined) {
            return 'slds-badge';
        }
        if (ewtMinutes < 2) {
            return 'slds-badge slds-theme_success';
        }
        if (ewtMinutes <= 5) {
            return 'slds-badge slds-theme_warning';
        }
        return 'slds-badge slds-theme_error';
    }

    async handleTransfer(event) {
        const queueId = event.currentTarget?.dataset?.queueId;
        if (!queueId || !this.recordId) {
            this.showToast('Erro', 'recordId ou queueId ausente.', 'error');
            return;
        }

        this.processingQueueId = queueId;
        this.refreshProcessingFlags();
        try {
            await transferRecordToQueue({ recordId: this.recordId, queueId });
            this.showToast('Sucesso', 'Sessão transferida para a fila com sucesso.', 'success');
        } catch (error) {
            this.showToast('Erro', this.extractError(error), 'error');
        } finally {
            this.processingQueueId = undefined;
            this.refreshProcessingFlags();
            await this.refreshMetricsOnly();
        }
    }

    refreshProcessingFlags() {
        this.queues = this.queues.map((row) => {
            const disabled = !row.canTransfer || this.processingQueueId === row.queueId;
            return {
                ...row,
                isProcessing: this.processingQueueId === row.queueId,
                isTransferDisabled: disabled,
                transferButtonVariant: disabled ? 'border-filled' : 'brand'
            };
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    extractError(error) {
        return (
            error?.body?.message ||
            error?.message ||
            'Não foi possível concluir a operação no momento.'
        );
    }

}
