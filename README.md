# Enhanced Queue Transfer

LWC para o Salesforce Service Console que enriquece o fluxo de transferência de filas do Omni-Channel, exibindo métricas em tempo real (itens em espera e EWT) e restringindo as opções de destino às filas configuradas para o agente via Presence Configuration.

---

## Funcionalidades

### Lista de filas elegíveis
- Obtém a lista de filas diretamente da **native Omni bridge** (`window.enhancedQueueTransferOmniBridge`), garantindo alinhamento com o comportamento nativo do Enhanced Conversation.
- Fallback automático via **Apex** (`getTransferQueues`) quando a bridge não está disponível.
- Respeita a **PresenceUserConfig** do agente logado: se `OptionsIsAllowAnyDestinationQueueForTransferEnabled = false`, exibe apenas as filas vinculadas aos `UserConfigTransferButton` / `LiveChatButton` configurados no perfil de presença.

### Métricas em tempo real
| Coluna | Fonte |
|---|---|
| **Em espera** | Cadeia híbrida: `PendingServiceRouting (IsReadyForRouting=true)` → fallback `MessagingSession (Status='Waiting')` |
| **EWT(m)** | Cadeia híbrida: `PendingServiceRouting` (idade do item mais antigo) → `MessagingSession` → `SDO_Service_Queue_Stat__c` |

- Métricas atualizadas automaticamente a cada **10 segundos** sem recarregar o componente.
- Botão de **refresh manual** (ícone ↺) força recarga completa da lista de filas + métricas.

### Busca dinâmica de filas
- Campo de busca com **debounce de 250 ms** filtra a lista em tempo real pelo nome da fila.

### Transferência
- Para **VoiceCall**, tenta primeiro a bridge nativa (`window.enhancedQueueTransferOmniBridge`) para transferir via runtime de voz (SCV / Agentforce CC Voice).
- Se a bridge de Voice não estiver disponível no contexto, usa fallback via **Apex** (`transferRecordToQueue`).
- Para **MessagingSession**, mantém transferência via **Apex** (`transferRecordToQueue`).
- O botão de transferência é **habilitado apenas quando o `MessagingSession` está `Active`**.
- Em **VoiceCall**, o botão fica habilitado apenas enquanto `EndTime` estiver vazio (chamada em andamento).
- O status é monitorado em tempo real via **`@wire(getRecord)`** da `lightning/uiRecordApi` — sem polling, sem cache.
- Durante o processamento, o botão da fila selecionada fica desabilitado para evitar duplo clique.

### Estados visuais do botão de transferência
| Estado da Sessão | Botão |
|---|---|
| `Active` | Azul (`brand`) — habilitado |
| `Waiting`, `Ended`, outros | Cinza (`border-filled` + `disabled`) |

### Segurança Apex
- Todas as queries SOQL usam `WITH SECURITY_ENFORCED` ou `Database.query` dinâmico (para objetos de feature-flag).
- Operações DML passam por `Security.stripInaccessible(AccessType.UPDATABLE, ...)`.
- Classe declarada com `with sharing` para respeitar regras de compartilhamento da org.

---

## Arquitetura

```
enhancedQueueTransfer (LWC)
│
├── @wire(getRecord) → MessagingSession.Status / VoiceCall.EndTime
│   └── transferAllowed getter (reativo, sem polling)
│
├── connectedCallback()
│   └── loadQueues()            ← carga completa: filas + métricas
│       ├── fetchNativeTransferQueues()   ← native Omni bridge
│       ├── getTransferQueues (Apex)      ← fallback
│       ├── getQueueMetrics (Apex)        ← métricas por ID
│       └── getQueueMetricsByNames (Apex) ← métricas por nome
│
├── scheduleNextRefresh()
│   └── refreshMetricsOnly()    ← refresh leve a cada 10s (só métricas)
│
└── handleTransfer()
    ├── transferVoiceCall()           ← bridge nativa (Voice) com fallback
    ├── transferRecordToQueue (Apex)  ← Messaging / fallback
    └── refreshMetricsOnly()

EnhancedQueueTransferController (Apex)
├── getTransferQueues()         ← filas elegíveis com PresencePolicy
├── getQueueMetrics()           ← métricas por ID de fila
├── getQueueMetricsByNames()    ← métricas por nome de fila
├── transferRecordToQueue()     ← transferência via OwnerId
└── Providers
    ├── LiveQueueAnalyticsProvider   ← PSR + MessagingSession + SDO_Service_Queue_Stat__c
    ├── MockQueueAnalyticsProvider   ← usado em testes
    └── EmptyQueueAnalyticsProvider  ← fallback em runtime (exibe --)

enhancedQueueTransferHost (Aura wrapper)
├── injeta `lightning:omniToolkitAPI`
└── publica `window.enhancedQueueTransferOmniBridge` para o LWC
```

---

## Objetos e APIs utilizados

| Objeto / API | Uso |
|---|---|
| `MessagingSession` | Fallback de contagem/EWT e monitoramento de `Status` via `uiRecordApi` |
| `PendingServiceRouting` | Fonte primária de waiting/EWT para Voice e Omni |
| `VoiceCall` | Monitoramento de `EndTime` via `uiRecordApi` para habilitar/desabilitar transferência |
| `SDO_Service_Queue_Stat__c` | EWT (`Avg_Queue_Time__c`) por nome de fila |
| `Group` (Type=Queue) | Resolução de nome canônico da fila por ID |
| `QueueSobject` | Filas associadas ao tipo de objeto (VoiceCall / MessagingSession) |
| `PresenceUserConfigUser` | Mapeamento usuário → configuração de presença |
| `PresenceUserConfig` | Flag `OptionsIsAllowAnyDestinationQueueForTransferEnabled` |
| `UserConfigTransferButton` | Botões de transferência configurados na presença |
| `LiveChatButton` | QueueId associado a cada botão de transferência |
| `lightning/uiRecordApi` | `@wire(getRecord)` para status reativo (Messaging e Voice) |
| `lightning:omniToolkitAPI` (Aura) | Bridge de transferência nativa para Voice |

---

## Exposição do componente

O componente está disponível nas **Record Pages** dos seguintes objetos:

| Objeto | Contexto |
|---|---|
| `MessagingSession` | `lightning__RecordPage` |
| `VoiceCall` | `lightning__RecordPage` (adicionar via App Builder) |

Configurar via **App Builder** → página de registro do objeto desejado.

Para **VoiceCall** (Service Cloud Voice e Agentforce Contact Center Voice), prefira adicionar
o wrapper Aura `Enhanced Queue Transfer Host`, que injeta a bridge nativa de transferência
(`window.enhancedQueueTransferOmniBridge`) usada pelo LWC para executar transferências reais de voz.

Para **MessagingSession**, use o LWC `Enhanced Queue Transfer` diretamente.

---

## Instalação

### Pré-requisitos
- Salesforce CLI v2 (`sf`) instalado
- Omni-Channel habilitado na org
- Presence Configuration criada e associada ao perfil do agente
- Permissão de leitura em `MessagingSession`, `SDO_Service_Queue_Stat__c` e objetos de presença

### Deploy direto (sandbox / org de desenvolvimento)

```bash
sf project deploy start \
  --source-dir force-app \
  --target-org <alias-da-org> \
  --wait 30
```

### Instalação via Unlocked Package (produção)

| Campo | Valor |
|---|---|
| Nome | Enhanced Queue Transfer |
| Namespace | *(sem namespace)* |
| Tipo | Unlocked Package |
| Versão | 1.1.0.2 |
| SubscriberPackageVersionId | `04tHp000001RdEhIAK` |
| Status | **Promovido (Released)** |
| Mudanças | EWT híbrido (PendingServiceRouting → MessagingSession → SDO), filtro stale 24h, label `EWT(m)`, query Omni dinâmica |

**Instalar em produção:**
```
https://login.salesforce.com/packaging/installPackage.apexp?p0=04tHp000001RdEhIAK
```

**Instalar em sandbox:**
```
https://test.salesforce.com/packaging/installPackage.apexp?p0=04tHp000001RdEhIAK
```

### Versões anteriores

| Versão | SubscriberPackageVersionId | Status |
|---|---|---|
| 1.0.0.1 | `04tHp000001RdEXIA0` | Released (deprecated) |

---

## Testes

```bash
sf apex run test \
  --class-names EnhancedQueueTransferControllerTest \
  --target-org <alias-da-org> \
  --result-format human \
  --wait 10
```

---

## Estrutura do projeto

```
EnhancedQueueTransfer/
├── force-app/main/default/
│   ├── classes/
│   │   ├── EnhancedQueueTransferController.cls
│   │   └── EnhancedQueueTransferControllerTest.cls
│   ├── aura/enhancedQueueTransferHost/
│   │   ├── enhancedQueueTransferHost.cmp
│   │   ├── enhancedQueueTransferHostController.js
│   │   ├── enhancedQueueTransferHostHelper.js
│   │   └── enhancedQueueTransferHost.design
│   └── lwc/enhancedQueueTransfer/
│       ├── enhancedQueueTransfer.html
│       ├── enhancedQueueTransfer.js
│       ├── enhancedQueueTransfer.css
│       └── enhancedQueueTransfer.js-meta.xml
├── config/project-scratch-def.json
├── sfdx-project.json
└── README.md
```
