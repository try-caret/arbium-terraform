# Queued upload recovery (AWS SQS and GCP Pub/Sub)

This customer-safe procedure applies to both cloud foundations in this repository.
Use the copy shipped with your pinned release. Alarm notifications link to
[this public copy](https://github.com/try-caret/arbium-terraform/blob/main/aws/customer/QUEUE_RECOVERY.md).
The release must publish this document before operators apply the new alarm definitions.
It does not require access to the private application repository.

## Enablement and rollback

Queue provisioning and application enablement are separate, approved changes. Both
application flags default off. Use a published chart/image release containing queue
support; older install-guide example pins do not imply support for these settings.

1. Provision the broker, workload permissions and notification targets with a reviewed
   Terraform plan. Verify the account/project, backend and matching environment inputs.
   AWS: `enable_capture_queue=true` requires `enable_capturelake=true` and existing
   SNS targets in `capture_queue_alarm_actions`. GCP: configure the `capture_queue`
   object with existing publisher/consumer identities and notification channels.
2. Use the `capture_queue` Terraform output to configure existing chart hooks:
   `serviceAccount.edgeFns.annotations`, `serviceAccount.capturelake.annotations`,
   `edgeFns.env` and `capturelake.env`. An annotation alone does not grant permissions.
   On AWS, use `eks.amazonaws.com/role-arn`; on GCP, use `iam.gke.io/gcp-service-account`.
   Configure `CAPTURE_QUEUE_PROVIDER` on both workloads, plus:
   - SQS: `CAPTURE_QUEUE_URL`, `AWS_REGION`.
   - Pub/Sub: `CAPTURE_QUEUE_TOPIC`; also `CAPTURE_QUEUE_SUBSCRIPTION` on the consumer.
   The writer needs a working embedding endpoint (`EMBEDDER_URL`, including
   `/invocations`) and any required invocation/authentication permissions. For a
   SageMaker deployment, use `SAGEMAKER_EMBEDDER_ENDPOINT` instead and grant scoped
   `sagemaker:InvokeEndpoint` permission; keep edge embedding access for rollback.
3. Deploy the single writer with deduplication and `Recreate`. Enable
   `CAPTURE_QUEUE_CONSUMER_ENABLED=true` on it, then verify receive, embedding,
   persistence and acknowledgement with approved test data before enabling
   `CAPTURE_INGEST_QUEUED=true` on edge. Confirm native dead-letter routing and alerts.
4. For rollback, disable **edge publication first**. Keep the consumer enabled until
   previously accepted messages drain. Inline and queued writes use the same writer;
   do not remove queue support or destroy queues/subscriptions while work remains.

HTTP 200 means durably accepted when queued, not immediately searchable. Partial or
uncertain publication returns an error for whole-request retry, never inline fallback.
Identifiers and event timestamps must remain unchanged on retries for deduplication.

## Alerts and finite retention

Monitor source backlog, oldest unacknowledged age, in-flight messages, dead-letter
backlog and dead-letter age in CloudWatch or Cloud Monitoring. Route notifications to
an attended on-call destination and test delivery before enablement.

| Alarm | Response |
| --- | --- |
| Source age >60 seconds sustained for 5 minutes | Investigate loss of freshness now; check writer readiness, embedding and storage/catalog dependencies |
| Source age >24 hours | Escalate outage recovery and remaining retention; plan catch-up while new uploads continue |
| Any visible dead-letter messages | Investigate immediately; these can be valid uploads, not disposable bad data |
| Dead-letter age >1 hour | Escalate repair/replay; do not wait for expiration |

Defaults are **14 days for SQS source and DLQ**, **31 days for Pub/Sub source and
DLQ subscriptions**. Unfinished work can expire: there is no indefinite archive or
automatic reconstruction service. For **SQS Standard**, DLQ expiration still uses the
original enqueue time, whereas its age metric measures time since transfer. A one-hour
DLQ age can therefore hide very little remaining retention. Check original age and
investigate every arrival; a DLQ-age alarm alone is insufficient.

Pub/Sub's configured five delivery attempts are approximate, not a strict retry bound.
Its service agent needs publisher rights on the dead-letter topic and subscriber rights
on the source subscription for forwarding/counting. Keep the DLQ subscription present.

Freshness alerts remain active during deployments, maintenance and catch-up. Do not
silently relax the 60-second target or suppress alerts; any maintenance silence needs
explicit operator approval. Queue age is a warning signal, not proof of end-to-end
search freshness or achieved throughput. Client-side buffering before acceptance is
volatile and limited; it is not protected by server queue retention.

## Diagnose and recover

1. Confirm the affected environment and source/DLQ identifiers. Inspect readiness,
   dependency availability, permission errors, rate/capacity limits and oldest message
   age. Use privacy-safe error stages and counts; never paste message bodies, embeddings,
   credentials or personal content into logs or tickets.
2. Restore catalog/storage and embedding dependencies. The consumer retains bounded
   active work, pauses normal intake and backs off on failures, renewing leases when
   possible. Lost/expired receipts do not discard buffered payloads. Unknown renewal
   failures hold the affected renewable message and pause normal intake, while healthy
   held siblings may finish. Poison and committed messages no longer need renewal, so a
   stale renewal result cannot block their release/acknowledgement. Successful writes are
   acknowledged only after all rows in that message have committed; uncertain writes retry
   through deduplication.
3. Size-sensitive embedding/commit failures halve the operation down to one record and
   reuse completed vectors and confirmed writes. Four full successful batches double
   that operation's cap toward its configured ceiling. Failed batches defer their
   messages for the rest of the processing pass; other already-held messages continue.
   Confirmed writes reset backoff. A unit failure earns one observation only when a
   **different message succeeds at the same operation in the same processing pass**
   (decoding, embedding or writing). The tracked unit's success clears its observations;
   passes without supporting success neither count nor reset. Its own other records
   cannot supply evidence. After **five accumulated observations**, the entire message
   stops receiving lease extensions without acknowledgement or immediate release.
   Natural expiry/redelivery may eventually send it to the DLQ. Shutdown and uncertain
   renewal retain it. Remove `CAPTURE_QUEUE_SINGLETON_FAILURE_LIMIT` before upgrading:
   startup rejects the old setting; the new observation threshold is fixed at five.

   One reserved control slot lets the consumer request one further message when all
   pending work has failed unit operations and nothing succeeded in that pass. Empty
   polls back off; an occupied failing control is not periodically replaced. A committed,
   removed or lease-lost control can free the role, but all retained payloads and pending
   acknowledgements still consume memory/message credits. Replacement requires spare
   capacity. This limits concurrent controls, not lifetime admissions across lease loss.
   The existing memory budget is unchanged; initial normal receive capacity is nine
   maximum-sized messages, reserving one additional message including vector storage.

   Retirement is **traffic-dependent, not a time guarantee or proof of invalid input**.
   One successful control pass supplies one observation, not five; cached results are
   not replayed as evidence. A lone failure with no traffic waits. Multiple failures
   and a failed control can require operator repair or quarantine before processing can
   continue. Use an approved writer pause and private broker inspection; preserve the
   original message in an approved recovery queue and confirm publication before deleting
   any source copy. Never purge a queue to clear a blocker.

   Confirmed decoding corruption is released immediately. Known allocation errors
   (`ENOMEM`, `Z_MEM_ERROR`, `ERR_MEMORY_ALLOCATION_FAILED`) retry and hold without
   observations; other decoding exceptions follow the same differential rule. There
   are no synthetic probes or processing error-text classifiers. Real sibling success
   does not guarantee equivalent workloads: user-specific permissions, long-text capacity
   limits or flapping dependencies can still move valid data into the DLQ. Restarts also
   cause broker redelivery. Attend `singleton-redrive` / `decode-redrive` and DLQ alerts,
   repair and replay before finite retention expires.
4. If a deliberate writer pause is needed, set `capturelake.replicaCount=0` through an
   approved full-values Helm change; resume with `1`. Never run multiple writers or
   force-delete a still-running writer. Pausing does not stop retention clocks.
5. An invalidated connection makes `/healthz` fail and retries opening every 30 seconds.
   `/livez` fails after continuous unhealth reaches `CAPTURELAKE_UNHEALTHY_RESTART_MS`
   (default 1200000, 20 minutes), allowing Kubernetes recovery. A healthy connection's
   embedding outage does not trip this gate. `PGCONNECT_TIMEOUT=60` bounds PostgreSQL
   connection establishment per host unless the DSN overrides it, **not** all native
   SQL/object-store operations. Do not mistake restart/backoff for repaired dependencies.
6. After repair, verify committed data and acknowledgement, falling source age/backlog,
   stable reader latency and no new DLQ arrivals. Rate-limit replay against live traffic.
   One writer remains mandatory; adding writers is not a safe catch-up strategy.

## Controlled dead-letter replay

1. Obtain approved operator replay permissions separately from workload roles. Privately
   inspect a small sample and fix the cause. Malformed envelopes need an explicitly
   reviewed repair, not blind replay. Never purge the source or DLQ as an incident fix.
2. Preserve the original validated gzip envelope and its capture IDs, event timestamps,
   user identity and `accepted_at`. Do not generate new IDs to make retry succeed.
   On SQS, use the native DLQ redrive facility at a conservative custom rate after
   confirming the destination source queue. See
   [AWS redrive permissions and controls](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-configure-dead-letter-queue-redrive.html).
3. On Pub/Sub, forwarding wraps the original message and adds source information. Use
   approved tooling to recover and validate the **original message data**; do not publish
   the forwarding wrapper as an upload envelope. Publish to the original source topic
   and acknowledge the DLQ copy only after confirmed publication. See
   [Pub/Sub dead-letter handling](https://cloud.google.com/pubsub/docs/dead-letter-topics).
4. Start with a small sample, verify persistence/deduplication, then increase replay rate
   only while freshness and reader latency remain acceptable. Uncertain publication
   leaves the DLQ copy available for retry. Even partly committed messages can be
   replayed unchanged: confirmed records are deduplicated.
5. Before processing older recovered data, review `DERIVE_LOOKBACK_DAYS` (default 3;
   `0` is unbounded for approved recovery). Widen it before deriving data outside the
   window. This only addresses the legacy selector's lookback; the XGBoost path can
   reject changes to completed episode membership and require an explicit rebuild.
   Coordinate that rebuild with support using the procedure for the installed release;
   widening lookback alone cannot guarantee reconciliation. Do not manually delete
   derived records or rewrite identities to bypass the checks.

Retention continues during investigation and replay. Escalate early if the remaining
window cannot accommodate recovery; do not promise recovery after provider expiration.
