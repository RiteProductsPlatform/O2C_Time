# Unprocessed Project Costs — Oracle Fusion Cloud Project Management REST API

**Resource:** Unprocessed Project Costs
**Base path:** `/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts`
**Version:** 11.13.18.05 (Fusion Applications 26c)
**Media type:** `application/json`
**Source:** https://docs.oracle.com/en/cloud/saas/project-management/26c/fapap/api-unprocessed-project-costs.html

The Unprocessed Project Costs resource is used to view, create, update, and delete unprocessed project costs. It supports costs that belong to both predefined and third-party transaction sources. To "send" costs to Fusion, you use the **POST (Create)** operation.

---

## 1. Endpoint Summary

| Task | Method | Path |
|------|--------|------|
| Create an unprocessed project cost | POST | `/unprocessedProjectCosts` |
| Get all unprocessed project costs | GET | `/unprocessedProjectCosts` |
| Get an unprocessed project cost | GET | `/unprocessedProjectCosts/{unprocessedProjectCostsUniqID}` |
| Update an unprocessed project cost | PATCH | `/unprocessedProjectCosts/{unprocessedProjectCostsUniqID}` |
| Delete an unprocessed project cost | DELETE | `/unprocessedProjectCosts/{unprocessedProjectCostsUniqID}` |

Child resources: `Errors`, `ProjectStandardCostCollectionFlexfields`, `UnprocessedCostRestDFF`.

---

## 2. Authentication

Basic auth (or OAuth) over HTTPS. Example uses a PPM cloud user:

```
curl --user ppm_cloud_user --header "Content-Type: application/json" \
  https://your_organization.com:port/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts
```

---

## 3. Create an Unprocessed Project Cost (Send to Fusion)

**POST** `/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts`

### Header Parameters
| Header | Type |
|--------|------|
| Effective-Of | string |
| Metadata-Context | string |
| REST-Framework-Version | string |
| Upsert-Mode | string |

### Request Body Parameters
Required fields are marked **(required)**. Minimum needed to send a cost: **BusinessUnitId**, **ExpenditureBatch**, **OriginalTransactionReference**, **Quantity**, plus the `ProjectStandardCostCollectionFlexfields` block (project, task, expenditure type, date, organization).

| Field | Type | Req |
|-------|------|-----|
| AccountingDate | string (date) | |
| AccrualItemFlag | boolean | |
| AssignmentId | integer(int64) | |
| AssignmentName | string | |
| AssignmentNumber | string | |
| BatchDescription | string | |
| BurdenCostCreditAccount | string | |
| BurdenCostCreditAccountCombinationId | integer(int64) | |
| BurdenCostDebitAccount | string | |
| BurdenCostDebitAccountCombinationId | integer(int64) | |
| BurdenedCostCreditAccount | string | |
| BurdenedCostCreditAccountCombinationId | integer(int64) | |
| BurdenedCostDebitAccount | string | |
| BurdenedCostDebitAccountCombinationId | integer(int64) | |
| BurdenedCostInProviderLedgerCurrency | number | |
| BurdenedCostInTransactionCurrency | number | |
| BurdenedCostRateInTransactionCurrency | number | |
| BusinessUnit | string | |
| BusinessUnitId | integer(int64) | **required** |
| Comment | string | |
| ConvertedFlag | boolean | |
| Document | string | |
| DocumentEntry | string | |
| DocumentEntryId | integer(int64) | |
| DocumentId | integer(int64) | |
| Email | string | |
| Errors | array (child) | |
| ExpenditureBatch | string | **required** |
| InventoryItem | string | |
| InventoryItemId | integer(int64) | |
| InventoryItemNumber | string | |
| Job | string | |
| JobId | integer(int64) | |
| NonlaborResource | string | |
| NonlaborResourceId | integer(int64) | |
| NonlaborResourceOrganization | string | |
| NonlaborResourceOrganizationId | integer(int64) | |
| OriginalTransactionReference | string | **required** |
| PersonId | integer(int64) | |
| PersonName | string | |
| PersonNumber | string | |
| PersonType | string | |
| PersonTypeCode | string | |
| ProjectRoleId | integer(int64) | |
| ProjectRoleName | string | |
| ProjectStandardCostCollectionFlexfields | array (child) | |
| ProviderLedgerCurrency | string | |
| ProviderLedgerCurrencyCode | string | |
| ProviderLedgerCurrencyConversionDate | string (date) | |
| ProviderLedgerCurrencyConversionDateTypeCode | string | |
| ProviderLedgerCurrencyConversionRate | number | |
| ProviderLedgerCurrencyConversionRateTypeId | string | |
| ProviderLedgerCurrencyConversionRoundingLimit | number | |
| Quantity | number | **required** |
| RawCostCreditAccount | string | |
| RawCostCreditAccountCombinationId | integer(int64) | |
| RawCostDebitAccount | string | |
| RawCostDebitAccountCombinationId | integer(int64) | |
| RawCostInProjectCurrency | number | |
| RawCostInProviderLedgerCurrency | number | |
| RawCostInTransactionCurrency | number | |
| RawCostRateInTransactionCurrency | number | |
| ReversedOriginalTransactionReference | string | |
| Status | string | |
| StatusCode | string | |
| TransactionCurrency | string | |
| TransactionCurrencyCode | string | |
| TransactionSource | string | |
| TransactionSourceId | integer(int64) | |
| UnitOfMeasure | string | |
| UnitOfMeasureCode | string | |
| UnmatchedNegativeTransactionFlag | boolean | |
| UnprocessedCostRestDFF | array (child) | |
| WorkTypeId | integer(int64) | |

### Request Body Example
```json
{
  "ExpenditureBatch": "My Expenditure Batch",
  "BusinessUnit": "Vision Operations",
  "TransactionSource": " Misc_Third party source uncosted",
  "Document": " Misc_Third party document uncosted",
  "DocumentEntry": " Misc_Third party doc entry uncosted",
  "PersonName": "Pooja Kapoor",
  "TransactionCurrencyCode": "USD",
  "OriginalTransactionReference": "1011",
  "Quantity": 42,
  "ProjectStandardCostCollectionFlexfields": [
    {
      "_EXPENDITURE_ITEM_DATE": "2012-03-26",
      "_PROJECT_ID_Display": "0002 PJS CDRM AM",
      "_TASK_ID_Display": "1.1",
      "_EXPENDITURE_TYPE_ID_Display": "Administration",
      "_ORGANIZATION_ID_Display": "Vision Operations"
    }
  ]
}
```

### cURL
```
curl --user ppm_cloud_user -X POST -d @example_request_payload.json \
  --header "Content-Type: application/json" \
  https://your_organization.com:port/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts
```

### Response Body Example (abridged)
```json
{
  "UnprocessedTransactionReferenceId": 300100185058528,
  "ExpenditureBatch": "My Expenditure Batch",
  "BusinessUnit": "Vision Operations",
  "BusinessUnitId": 204,
  "TransactionSource": " Misc_Third party source uncosted",
  "TransactionSourceId": 100000015914968,
  "StatusCode": "P",
  "ProjectName": "0002 PJS CDRM AM",
  "ProjectId": 300100023161776,
  "TaskNumber": "1.1",
  "ExpenditureItemDate": "2012-03-26",
  "ExpenditureType": "Administration",
  "ExpenditureOrganization": "Vision Operations",
  "PersonName": "Pooja Kapoor",
  "PersonNumber": "100000017109026",
  "Quantity": 42,
  "OriginalTransactionReference": "1011",
  "ExpenditureEndingDate": "2012-04-01",
  "ProjectStandardCostCollectionFlexfields": [
    {
      "TxnInterfaceId": 300100185058528,
      "__FLEX_Context": "PJC_All",
      "_PROJECT_ID": 300100023161776,
      "_TASK_ID": 300100023161797,
      "_EXPENDITURE_ITEM_DATE": "2012-03-26",
      "_EXPENDITURE_TYPE_ID": 300100036998310,
      "_ORGANIZATION_ID": 204,
      "links": [ /* self / canonical / parent */ ]
    }
  ],
  "links": [ /* self, canonical, child: Errors, ProjectStandardCostCollectionFlexfields, UnprocessedCostRestDFF */ ]
}
```

> **Tip (sponsored / grants projects):** include `_CONTRACT_ID_Display` (award) and `_RESERVED_ATTRIBUTE1_Display` (funding source) inside the flexfield block.

The **full response body** returns the complete item schema (same field set as the "Get an unprocessed project cost" response listed in section 4), including derived values such as ProjectId, TaskId, ExpenditureTypeId, ExpenditureCategory, ExpenditureEndingDate, StatusCode, ErrorStage, and the child collections.

---

## 4. Get All Unprocessed Project Costs

**GET** `/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts`

### Query Parameters
| Parameter | Type |
|-----------|------|
| effectiveDate | string |
| expand | string |
| fields | string |
| finder | string |
| limit | integer |
| links | string |
| offset | integer |
| onlyData | boolean |
| orderBy | string |
| q | string |
| totalResults | boolean |

### Header Parameters
Effective-Of, Metadata-Context, REST-Framework-Version.

**Request body:** none.

### Response Body (collection wrapper)
| Field | Type | Req |
|-------|------|-----|
| count | integer | required |
| hasMore | boolean | required |
| items | array (Items) | |
| limit | integer | required |
| links | array (Links) | required |
| offset | integer | required |
| totalResults | integer | |

Each element of `items` is an unprocessedProjectCosts item (same schema as section 5).

### cURL
```
curl --user ppm_cloud_user \
  https://your_organization.com:port/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts
```

---

## 5. Get an Unprocessed Project Cost

**GET** `/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts/{unprocessedProjectCostsUniqID}`

### Path Parameters
| Parameter | Type | Req |
|-----------|------|-----|
| unprocessedProjectCostsUniqID | string | required |

### Query Parameters
| Parameter | Type |
|-----------|------|
| dependency | string |
| expand | string |
| fields | string |
| links | string |
| onlyData | boolean |

**Request body:** none.

### Response Body (item schema — full field list)
This is the complete item schema also returned by POST, PATCH, and each element of the GET-all `items` array:

AccountingDate (date), AccrualItemFlag (bool), AssignmentId, AssignmentName, AssignmentNumber, AwardBudgetPeriod, BatchDescription, BillableFlag (bool), BurdenCostCreditAccount, BurdenCostCreditAccountCombinationId, BurdenCostDebitAccount, BurdenCostDebitAccountCombinationId, BurdenedCostCreditAccount, BurdenedCostCreditAccountCombinationId, BurdenedCostDebitAccount, BurdenedCostDebitAccountCombinationId, BurdenedCostInProjectCurrency, BurdenedCostInProviderLedgerCurrency, BurdenedCostInReceiverLedgerCurrency, BurdenedCostInTransactionCurrency, BurdenedCostRateInTransactionCurrency, BusinessUnit, BusinessUnitId, CapitalizableFlag (bool), Comment, ContractId, ContractName, ContractNumber, ConvertedFlag (bool), Document, DocumentEntry, DocumentEntryId, DocumentId, Email, Errors (array), ErrorStage, ErrorStageCode, ExpenditureBatch, ExpenditureCategory, ExpenditureCategoryId, ExpenditureEndingDate (date), ExpenditureItemDate (date), ExpenditureOrganization, ExpenditureOrganizationId, ExpenditureType, ExpenditureTypeId, FundingSourceId, FundingSourceName, FundingSourceNumber, FundsStatus, FundsStatusCode, InventoryItem, InventoryItemId, InventoryItemNumber, Job, JobId, links (array), NonlaborResource, NonlaborResourceId, NonlaborResourceOrganization, NonlaborResourceOrganizationId, OriginalTransactionReference, PersonId, PersonName, PersonNumber, PersonType, PersonTypeCode, ProjectCurrency, ProjectCurrencyCode, ProjectCurrencyConversionDate (date), ProjectCurrencyConversionDateTypeCode, ProjectCurrencyConversionRate, ProjectCurrencyConversionRateTypeId, ProjectId, ProjectName, ProjectNumber, ProjectRoleId, ProjectRoleName, ProjectStandardCostCollectionFlexfields (array), ProviderLedgerCurrency, ProviderLedgerCurrencyCode, ProviderLedgerCurrencyConversionDate (date), ProviderLedgerCurrencyConversionDateTypeCode, ProviderLedgerCurrencyConversionRate, ProviderLedgerCurrencyConversionRateTypeId, ProviderLedgerCurrencyConversionRoundingLimit, Quantity, RawCostCreditAccount, RawCostCreditAccountCombinationId, RawCostDebitAccount, RawCostDebitAccountCombinationId, RawCostInProjectCurrency, RawCostInProviderLedgerCurrency, RawCostInReceiverLedgerCurrency, RawCostInTransactionCurrency, RawCostRateInTransactionCurrency, ReceiverLedgerCurrency, ReceiverLedgerCurrencyCode, ReceiverLedgerCurrencyConversionDate (date), ReceiverLedgerCurrencyConversionDateTypeCode, ReceiverLedgerCurrencyConversionRate, ReceiverLedgerCurrencyConversionRateTypeId, ReversedOriginalTransactionReference, SourceDistributionLayerReference, SourceTransactionHeaderReference, SourceTransactionLineReference, SourceTransactionParentDistributionReference, SourceTransactionParentHeaderReference, SourceTransactionParentLineReference, SourceTransactionQuantity, SourceTransactionType, Status, StatusCode, SupplyChainTransactionActionId, SupplyChainTransactionSourceTypeId, SupplyChainTransactionTypeId, TaskId, TaskName, TaskNumber, TransactionCurrency, TransactionCurrencyCode, TransactionNumber, TransactionSource, TransactionSourceId, UnitOfMeasure, UnitOfMeasureCode, UnmatchedNegativeTransactionFlag (bool), UnprocessedCostRestDFF (array), UnprocessedTransactionReferenceId, WorkType, WorkTypeId.

### cURL
```
curl --user ppm_cloud_user \
  https://your_organization.com:port/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts/300100059831542
```

---

## 6. Update an Unprocessed Project Cost

**PATCH** `/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts/{unprocessedProjectCostsUniqID}`

### Path Parameters
| Parameter | Type | Req |
|-----------|------|-----|
| unprocessedProjectCostsUniqID | string | required |

### Header Parameters
Effective-Of, Metadata-Context, REST-Framework-Version.

### Request Body (updatable fields)
Send only the attributes you want to change. Updatable fields:

AccountingDate, AccrualItemFlag, AssignmentId, AssignmentName, AssignmentNumber, BatchDescription, BurdenCostCreditAccount, BurdenCostCreditAccountCombinationId, BurdenCostDebitAccount, BurdenCostDebitAccountCombinationId, BurdenedCostCreditAccount, BurdenedCostCreditAccountCombinationId, BurdenedCostDebitAccount, BurdenedCostDebitAccountCombinationId, BurdenedCostInProviderLedgerCurrency, BurdenedCostInTransactionCurrency, BurdenedCostRateInTransactionCurrency, Comment, ConvertedFlag, Email, Errors, ExpenditureBatch, InventoryItem, InventoryItemId, InventoryItemNumber, Job, JobId, NonlaborResource, NonlaborResourceId, NonlaborResourceOrganization, NonlaborResourceOrganizationId, OriginalTransactionReference, PersonId, PersonName, PersonNumber, PersonType, PersonTypeCode, ProjectRoleId, ProjectRoleName, ProjectStandardCostCollectionFlexfields, ProviderLedgerCurrency, ProviderLedgerCurrencyCode, ProviderLedgerCurrencyConversionDate, ProviderLedgerCurrencyConversionDateTypeCode, ProviderLedgerCurrencyConversionRate, ProviderLedgerCurrencyConversionRateTypeId, ProviderLedgerCurrencyConversionRoundingLimit, Quantity, RawCostCreditAccount, RawCostCreditAccountCombinationId, RawCostDebitAccount, RawCostDebitAccountCombinationId, RawCostInProjectCurrency, RawCostInProviderLedgerCurrency, RawCostInTransactionCurrency, RawCostRateInTransactionCurrency, ReversedOriginalTransactionReference, TransactionCurrency, TransactionCurrencyCode, UnitOfMeasure, UnitOfMeasureCode, UnmatchedNegativeTransactionFlag, UnprocessedCostRestDFF, WorkTypeId.

### Response Body
Returns the full unprocessedProjectCosts item schema (same as section 5).

### cURL
```
curl --user ppm_cloud_user -X PATCH -d @patch_payload.json \
  --header "Content-Type: application/json" \
  https://your_organization.com:port/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts/300100059831542
```

---

## 7. Delete an Unprocessed Project Cost

**DELETE** `/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts/{unprocessedProjectCostsUniqID}`

### Path Parameters
| Parameter | Type | Req |
|-----------|------|-----|
| unprocessedProjectCostsUniqID | string | required |

### Header Parameters
Effective-Of, Metadata-Context, REST-Framework-Version.

**Request body:** none.
**Response:** No Content — this task does not return elements in the response body.

### cURL
```
curl --user ppm_cloud_user -X DELETE \
  https://your_organization.com:port/fscmRestApi/resources/11.13.18.05/unprocessedProjectCosts/300100059831542
```

---

## 8. Standard Query Parameter Notes (GET all)

- **q** — row filter, e.g. `q=StatusCode='R'` (returns rejected/errored costs).
- **fields** — restrict returned attributes, e.g. `fields=UnprocessedTransactionReferenceId,StatusCode,ErrorStage`.
- **expand** — inline child resources, e.g. `expand=Errors` or `expand=all`.
- **limit / offset** — pagination.
- **orderBy** — sort, e.g. `orderBy=ExpenditureItemDate:desc`.
- **onlyData=true** — omit the `links` sections.
- **totalResults=true** — include `totalResults` count in the response.

## 9. Typical Integration Flow

1. **POST** each cost (or batch of costs) to send them to Fusion — response returns `UnprocessedTransactionReferenceId` and `StatusCode` ("P" = pending processing).
2. Run the **Import Costs / Process Costs** ESS program in Fusion to convert unprocessed costs into project costs.
3. **GET** with `q=StatusCode='R'` and `expand=Errors` to find rejections and read the `Errors` child for the reason.
4. **PATCH** to correct rejected rows, or **DELETE** rows that should be discarded, then re-process.
