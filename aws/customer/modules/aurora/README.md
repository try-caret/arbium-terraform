# Aurora module

Creates the ChainDB Aurora PostgreSQL database for customer AWS deployments.

Defaults are sized for small/pilot validation environments (≈20 users):

- Aurora PostgreSQL Serverless v2.
- One `db.serverless` writer instance.
- RDS-managed master password in Secrets Manager.
- Security group allowing Postgres from the EKS node security group.
- `pg_stat_statements` preloaded through a cluster parameter group.
- Performance Insights on with the free 7-day retention (`performance_insights_enabled`, `performance_insights_retention_period`), so a database stall leaves wait-event data to look at. It uses the AWS-managed key.

Terraform intentionally manages database infrastructure only. Schema migrations are run by the Helm chart (Flyway-based `chaindb-migrate`, either as an initContainer on edge-fns pods or as an optional pre-install Helm hook Job).
