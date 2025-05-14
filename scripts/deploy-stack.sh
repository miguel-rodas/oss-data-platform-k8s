#!/bin/bash
set -e

echo "🚀 Installing MinIO..."
helm install minio minio/minio -n minio --create-namespace -f values/minio-values.yaml

echo "✅ MinIO installed."

echo "🚀 Installing Airbyte..."
helm install airbyte airbyte/airbyte -n airbyte --create-namespace -f values/airbyte-values.yaml

echo "✅ Airbyte installed."

echo "🚀 Installing Airflow..."
helm install airflow apache-airflow/airflow -n airflow --create-namespace -f values/airflow-values.yaml
echo "✅ Airflow installed."

echo "🔧 Patching Airbyte webapp service to NodePort..."
kubectl patch svc airbyte-airbyte-webapp-svc -n airbyte \
  --type merge \
  -p '{
    "spec": {
      "type": "NodePort",
      "ports": [
        {
          "name": "http",
          "port": 8080,
          "targetPort": 8080,
          "protocol": "TCP",
          "nodePort": 30002
        }
      ]
    }
  }'

echo "🔧 Patching MinIO console service to NodePort..."
kubectl patch svc minio-console -n minio \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 9001, "targetPort": 9001, "protocol": "TCP", "nodePort": 30001}]}}'

echo "🔧 Patching Airflow API server service to NodePort..."
kubectl patch svc airflow-api-server -n airflow \
  --type merge \
  -p '{
    "spec": {
      "type": "NodePort",
      "ports": [
        {
          "name": "http",
          "port": 8080,
          "targetPort": 8080,
          "protocol": "TCP",
          "nodePort": 30004
        }
      ]
    }
  }'

echo "🎉 All components (MinIO, Airbyte, Airflow) deployed successfully!"
