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

if ! kubectl get storageclass | grep -q local-path; then
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  echo "⏳ Waiting for local-path-provisioner to be ready..."
  kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=60s

  echo "🔍 Verifying and enforcing local-path as the only default StorageClass..."
  DEFAULT_SC=$(kubectl get storageclass | grep '(default)' | awk '{print $1}')
  if [ "$DEFAULT_SC" != "local-path" ]; then
    echo "❌ Multiple or incorrect default storage classes found. Cleaning up..."
    kubectl patch storageclass "$DEFAULT_SC" -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  else
    echo "✅ local-path is already the default StorageClass."
  fi
else
  echo "✅ local-path provisioner already installed."
fi

# Add Helm repositories for external charts
# Add Helm repo for MinIO, Airbyte, Airflow, and Trino
echo "🔗 Adding Helm repositories..."

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add minio https://charts.min.io/
helm repo add airbyte https://airbytehq.github.io/helm-charts
helm repo add apache-airflow https://airflow.apache.org
helm repo add trinodb https://trinodb.github.io/charts
helm repo add starrocks https://starrocks.github.io/starrocks-kubernetes-operator
helm repo update

# MetalLB installation for LoadBalancer support
echo "📦 Installing MetalLB (LoadBalancer)..."
if ! kubectl get ns metallb-system &> /dev/null; then
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
  echo "⏳ Waiting for MetalLB pods to be ready..."
  kubectl wait --namespace metallb-system --for=condition=Ready pod --all --timeout=90s
  echo "✅ MetalLB installed."

  echo "⚙️  Configuring MetalLB IP pool..."
  kubectl apply -f ./kind/metallb-config.yaml
else
  echo "✅ MetalLB already installed."
fi

echo "🐘 Deploying shared PostgreSQL instance..."
# Create 'data' namespace and define init ConfigMap to pre-create airbyte_db and airflow_db
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
  --from-literal=init.sql="CREATE DATABASE airbyte_db; CREATE DATABASE airflow_db;" \
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

echo "✅ PostgreSQL deployed with airbyte_db and airflow_db."

echo "🚀 Installing MinIO..."
# Ensure a clean installation of MinIO
if helm status minio -n minio &> /dev/null; then
  echo "🧼 Deleting existing MinIO release to avoid upgrade conflict..."
  helm uninstall minio -n minio
  kubectl delete pvc -n minio --all
fi
helm install minio minio/minio -n minio --create-namespace -f values/minio-values.yaml

echo "✅ MinIO installed."

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

# StarRocks installation block
echo "🚀 Installing StarRocks..."
# Ensure a clean installation of StarRocks
if helm status starrocks -n starrocks &> /dev/null; then
  echo "🧼 Deleting existing StarRocks release to avoid upgrade conflict..."
  helm uninstall starrocks -n starrocks
  kubectl delete pvc -n starrocks --all
fi
helm install starrocks starrocks/kube-starrocks -n starrocks --create-namespace -f values/starrocks-values.yaml
echo "✅ StarRocks installed."

echo "⏳ Waiting for the services to be ready..."
sleep 90

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

# Expose MinIO console via NodePort
echo "🔧 Patching MinIO console service to NodePort..."
kubectl patch svc minio-console -n minio \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 9001, "targetPort": 9001, "protocol": "TCP", "nodePort": 30001}]}}'

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

# Expose StarRocks FE service via NodePort
echo "🔧 Patching StarRocks FE service to NodePort..."
kubectl patch svc kube-starrocks-fe-service -n starrocks \
  --type merge \
  -p '{
    "spec": {
      "type": "NodePort",
      "ports": [
        {
          "name": "web-ui",
          "port": 8030,
          "targetPort": 8030,
          "protocol": "TCP",
          "nodePort": 30004
        },
        {
          "name": "rpc-port",
          "port": 9020,
          "targetPort": 9020,
          "protocol": "TCP",
          "nodePort": 30007
        },
        {
          "name": "http-api",
          "port": 9010,
          "targetPort": 9010,
          "protocol": "TCP",
          "nodePort": 30008
        }
      ]
    }
  }'

echo "✅ StarRocks FE NodePorts exposed: 8030 (UI), 9020 (RPC), 9010 (HTTP API)."

# Expose StarRocks BE service via NodePort
echo "🔧 Patching StarRocks BE service to NodePort..."
kubectl patch svc kube-starrocks-be-service -n starrocks \
  --type merge \
  -p '{
    "spec": {
      "type": "NodePort",
      "ports": [
        {
          "name": "webserver-port",
          "port": 8040,
          "targetPort": 8040,
          "protocol": "TCP",
          "nodePort": 30006
        }
      ]
    }
  }'

# Patch StarRocks FE LoadBalancer service to expose MySQL port 9030
echo "🔧 Patching StarRocks FE LoadBalancer service for MySQL access..."
kubectl patch svc kube-starrocks-fe-service -n starrocks \
  --type merge \
  -p '{
    "spec": {
      "type": "LoadBalancer",
      "ports": [
        {
          "name": "mysql",
          "port": 9030,
          "targetPort": 9030,
          "protocol": "TCP"
        }
      ]
    }
  }'

echo "✅ StarRocks FE LoadBalancer patched to expose MySQL-compatible port 9030."
