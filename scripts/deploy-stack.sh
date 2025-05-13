#!/bin/bash
set -e

echo "🚀 Installing MinIO..."
helm install minio minio/minio -n minio --create-namespace -f values/minio-values.yaml

echo "✅ MinIO installed."

echo "🚀 Installing Airbyte..."
helm install airbyte airbyte/airbyte -n airbyte --create-namespace -f values/airbyte-values.yaml


echo "✅ Airbyte installed."

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

echo "🎉 All components deployed successfully!"

