#!/bin/bash

# Create Kind cluster if it doesn't exist
if ! kind get clusters | grep -q '^kind$'; then
  echo "🛠️ Creating Kind cluster..."
  kind create cluster --config kind/kind-config.yaml
else
  echo "✅ Kind cluster already exists."
fi

set -e

# Ensure local-path provisioner is installed
echo "📦 Ensuring local-path provisioner is installed..."

if ! kubectl get storageclass local-path &> /dev/null; then
  echo "📦 Applying local-path-provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  echo "⏳ Waiting for local-path-provisioner to be ready..."
  kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=60s
else
  echo "✅ local-path provisioner already installed."
fi

echo "🔍 Verifying and enforcing local-path as the only default StorageClass..."
if kubectl get storageclass local-path &> /dev/null; then
  CURRENT_DEFAULT=$(kubectl get storageclass | awk '/\(default\)/ {print $1}')
  if [ -n "$CURRENT_DEFAULT" ] && [ "$CURRENT_DEFAULT" != "local-path" ]; then
    echo "❌ '$CURRENT_DEFAULT' is currently default. Switching to local-path..."
    kubectl patch storageclass "$CURRENT_DEFAULT" -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  elif [ -z "$CURRENT_DEFAULT" ]; then
    echo "❌ No default StorageClass set. Setting local-path as default..."
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  else
    echo "✅ local-path is already the default StorageClass."
  fi
else
  echo "❌ 'local-path' StorageClass not found. Ensure the provisioner was installed correctly."
  exit 1
fi

# Add Helm repositories for external charts
echo "🔗 Adding Helm repositories..."

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add minio https://charts.min.io/
helm repo add airbyte https://airbytehq.github.io/helm-charts
helm repo add apache-airflow https://airflow.apache.org
helm repo add trino https://trinodb.github.io/charts
helm repo add nessie-helm https://charts.projectnessie.org
helm repo update

echo "🐘 Deploying shared PostgreSQL instance..."
# Create 'data' namespace and define init ConfigMap to pre-create airbyte_db, airflow_db and nessie_db
kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f -

# Ensure a clean installation of PostgreSQL
if helm status postgres -n data &> /dev/null; then
  echo "🧼 Deleting existing PostgreSQL release to avoid upgrade conflict..."
  helm uninstall postgres -n data
  kubectl delete pvc -n data --all
  kubectl delete configmap pg-init-scripts -n data --ignore-not-found
fi

kubectl create configmap pg-init-scripts \
  --namespace data \
  --from-literal=init.sql="CREATE DATABASE airbyte_db; CREATE DATABASE airflow_db; CREATE DATABASE nessie_db;" \
  --dry-run=client -o yaml | kubectl apply -f -

# Ensure the pg-init-scripts ConfigMap is available before proceeding with PostgreSQL installation
kubectl wait --for=condition=Established configmap/pg-init-scripts -n data --timeout=10s || true

helm upgrade --install postgres bitnami/postgresql \
  --namespace data \
  --set auth.postgresPassword=postgrespw \
  --set auth.database=postgres \
  --set primary.initdb.user=postgres \
  --set primary.initdb.password=postgrespw \
  --set primary.initdb.scriptsConfigMap=pg-init-scripts

echo "✅ PostgreSQL deployed with airbyte_db, airflow_db, and nessie_db databases."

echo "🚀 Installing MinIO..."
# Ensure a clean installation of MinIO
if helm status minio -n minio &> /dev/null; then
  echo "🧼 Deleting existing MinIO release to avoid upgrade conflict..."
  helm uninstall minio -n minio
  kubectl delete pvc -n minio --all
fi
helm install minio minio/minio -n minio --create-namespace -f values/minio-values.yaml
echo "✅ MinIO installed."

# Install Nessie prerequisites
echo "🚀 Installing Nessie..."
# Create namespace for Nessie if it doesn't exist
kubectl create namespace nessie-ns --dry-run=client -o yaml | kubectl apply -f -
echo "🔐 Creating secret for PostgreSQL credentials required by Nessie..."
kubectl create secret generic postgres-creds \
  --from-literal=postgres=postgres \
  --from-literal=postgrespw=postgrespw \
  -n nessie-ns --dry-run=client -o yaml | kubectl apply -f -
echo "🔐 Creating secret for MinIO credentials required by Nessie..."
kubectl create secret generic minio-creds \
  --from-literal=awsAccessKeyId=minioadmin \
  --from-literal=awsSecretAccessKey=minioadmin123 \
  -n nessie-ns --dry-run=client -o yaml | kubectl apply -f -
# Ensure a clean installation of Nessie
if helm status nessie -n nessie-ns &> /dev/null; then
  echo "🧼 Deleting existing Nessie release to avoid upgrade conflict..."
  helm uninstall nessie -n nessie-ns
  kubectl delete pvc -n nessie-ns --all
fi
helm install nessie nessie-helm/nessie --namespace nessie-ns --create-namespace -f values/nessie-values.yaml
echo "✅ Nessie installed."

echo "🚀 Installing Airbyte..."
# Ensure a clean installation of Airbyte
if helm status airbyte -n airbyte &> /dev/null; then
  echo "🧼 Deleting existing Airbyte release to avoid upgrade conflict..."
  helm uninstall airbyte -n airbyte
  kubectl delete svc airbyte-airbyte-webapp-svc -n airbyte --ignore-not-found
fi
helm install airbyte airbyte/airbyte -n airbyte --create-namespace -f values/airbyte-values.yaml
echo "✅ Airbyte installed."

echo "🚀 Installing Airflow..."
# Ensure a clean installation of Airflow
if helm status airflow -n airflow &> /dev/null; then
  echo "🧼 Deleting existing Airflow release to avoid upgrade conflict..."
  helm uninstall airflow -n airflow
  kubectl delete svc airflow-api-server -n airflow --ignore-not-found
fi
helm install airflow apache-airflow/airflow -n airflow --create-namespace -f values/airflow-values.yaml --timeout 10m
echo "✅ Airflow installed."

# Trino installation block
echo "🚀 Installing Trino..."
# Ensure a clean installation of Trino
if helm status trino -n trino &> /dev/null; then
  echo "🧼 Deleting existing Trino release to avoid upgrade conflict..."
  helm uninstall trino -n trino
  kubectl delete pvc -n trino --all
fi
helm install trino trino/trino -n trino --create-namespace -f values/trino-values.yaml
echo "✅ Trino installed."

# Wait for all services to be ready
echo "⏳ Waiting for the services to be ready..."
sleep 90

# Expose MinIO console via NodePort
echo "🔧 Patching MinIO console service to NodePort..."
kubectl patch svc minio-console -n minio \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 9001, "targetPort": 9001, "protocol": "TCP", "nodePort": 30001}]}}'
echo "✅ MinIO NodePort exposed: 9901 -> 30001."

# Expose Nessie service via NodePort
echo "🔧 Patching Nessie service to NodePort..."
kubectl patch svc nessie -n nessie-ns \
  --type merge \
  -p '{
    "spec": {
      "type": "NodePort",
      "ports": [
        {
          "port": 19120,
          "targetPort": 19120,
          "protocol": "TCP",
          "nodePort": 30004
        }
      ]
    }
  }'
echo "✅ Nessie NodePort exposed: 19120 -> 30004."

# Expose Trino coordinator via NodePort
echo "🔧 Patching Trino coordinator service to NodePort..."
kubectl patch svc trino -n trino \
  --type merge \
  -p '{
    "spec": {
      "type": "NodePort",
      "ports": [
        {
          "port": 8080,
          "targetPort": 8080,
          "protocol": "TCP",
          "nodePort": 30005
        }
      ]
    }
  }'
echo "✅ Trino NodePort exposed: 8080 -> 30005."

# Expose Airbyte webapp via NodePort
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
echo "✅ Airbyte NodePort exposed: 8080 -> 30002."

# Expose Airflow API server via NodePort
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
          "nodePort": 30003
        }
      ]
    }
  }'
echo "✅ Airflow NodePort exposed: 8080 -> 30003."

echo "🎉 All services deployed successfully. Your open data platform is ready!"
