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
| **Em espera** | Contagem de `MessagingSession` com `Status = 'Waiting'` e `OwnerId` igual ao ID da fila |
| **EWT(s)** | `SDO_Service_Queue_Stat__c.Avg_Queue_Time__c` vinculado pelo nome da fila |

- Métricas atualizadas automaticamente a cada **10 segundos** sem recarregar o componente.
- Botão de **refresh manual** (ícone ↺) força recarga completa da lista de filas + métricas.

### Busca dinâmica de filas
- Campo de busca com **debounce de 250 ms** filtra a lista em tempo real pelo nome da fila.

### Transferência
- Transfere o registro atual via **Apex** (`transferRecordToQueue`), alterando o `OwnerId` para a fila destino — mecanismo nativo e documentado do Omni-Channel.
- O botão de transferência é **habilitado apenas quando o `MessagingSession` está `Active`**.
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
├── @wire(getRecord) → MessagingSession.Status
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
    ├── transferRecordToQueue (Apex) ← mudança de OwnerId (mecanismo principal)
    └── refreshMetricsOnly()

EnhancedQueueTransferController (Apex)
├── getTransferQueues()         ← filas elegíveis com PresencePolicy
├── getQueueMetrics()           ← métricas por ID de fila
├── getQueueMetricsByNames()    ← métricas por nome de fila
├── transferRecordToQueue()     ← transferência via OwnerId
└── Providers
    ├── LiveQueueAnalyticsProvider   ← MessagingSession + SDO_Service_Queue_Stat__c
    ├── MockQueueAnalyticsProvider   ← usado em testes
    └── EmptyQueueAnalyticsProvider  ← fallback em runtime (exibe --)
```

---

## Objetos e APIs utilizados

| Objeto / API | Uso |
|---|---|
| `MessagingSession` | Contagem de sessões em espera; monitoramento de `Status` via `uiRecordApi` |
| `SDO_Service_Queue_Stat__c` | EWT (`Avg_Queue_Time__c`) por nome de fila |
| `Group` (Type=Queue) | Resolução de nome canônico da fila por ID |
| `QueueSobject` | Filas associadas ao tipo de objeto (VoiceCall / MessagingSession) |
| `PresenceUserConfigUser` | Mapeamento usuário → configuração de presença |
| `PresenceUserConfig` | Flag `OptionsIsAllowAnyDestinationQueueForTransferEnabled` |
| `UserConfigTransferButton` | Botões de transferência configurados na presença |
| `LiveChatButton` | QueueId associado a cada botão de transferência |
| `lightning/uiRecordApi` | `@wire(getRecord)` para status reativo da sessão |

---

## Exposição do componente

O componente está disponível nas **Record Pages** dos seguintes objetos:

| Objeto | Contexto |
|---|---|
| `MessagingSession` | `lightning__RecordPage` |
| `VoiceCall` | `lightning__RecordPage` (adicionar via App Builder) |

Configurar via **App Builder** → página de registro do objeto desejado → arrastar o componente `Enhanced Queue Transfer`.

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
│   └── lwc/enhancedQueueTransfer/
│       ├── enhancedQueueTransfer.html
│       ├── enhancedQueueTransfer.js
│       ├── enhancedQueueTransfer.css
│       └── enhancedQueueTransfer.js-meta.xml
├── config/project-scratch-def.json
├── sfdx-project.json
└── README.md
```
