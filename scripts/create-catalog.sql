CREATE EXTERNAL CATALOG iceberg_catalog_bronze
PROPERTIES
(
  "type" = "iceberg",
  "iceberg.catalog.type" = "rest",
  "iceberg.catalog.uri" = "http://nessie.nessie-ns.svc.cluster.local:30009/iceberg/bronze",
  "iceberg.catalog.warehouse" = "s3a://warehouse",
  "aws.s3.access_key" = "minioadmin",
  "aws.s3.secret_key" = "minioadmin123",
  "aws.s3.endpoint" = "http://minio.minio.svc.cluster.local:9000",
  "aws.s3.enable_path_style_access" = "true",
  "aws.s3.enable_ssl" = "false",
  "client.factory" = "com.starrocks.connector.iceberg.IcebergAwsClientFactory"
);