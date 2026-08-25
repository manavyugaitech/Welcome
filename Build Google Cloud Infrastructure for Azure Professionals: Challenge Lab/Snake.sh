#!/bin/bash

# --- Color & Formatting Setup ---
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'

# Foreground Colors
CYAN='\033[38;5;51m'
BLUE='\033[38;5;39m'
GREEN='\033[38;5;48m'
YELLOW='\033[38;5;220m'
RED='\033[38;5;196m'
PURPLE='\033[38;5;141m'

# Visual Helper Functions
banner() {
  echo -e "${CYAN}${BOLD}"
  echo "┌──────────────────────────────────────────────────────────────────┐"
  echo "│           WELCOME TO MANAVYUG AI                                 │"
  echo "└──────────────────────────────────────────────────────────────────┘"
  echo -e "${RESET}"
}

log_section() {
  echo -e "\n${BLUE}${BOLD}┌── [ SECTION: $1 ]${RESET}"
}

log_step() {
  echo -e "${YELLOW}${BOLD} ├─►${RESET} $1"
}

log_info() {
  echo -e "${CYAN}${BOLD} ├─ℹ${RESET} $1"
}

log_success() {
  echo -e "${GREEN}${BOLD} └─✔${RESET} $1"
}

clear
banner

# --- Zone & Project Configuration ---
echo -e "${YELLOW}${BOLD}? Please enter your preferred zone (e.g., us-central1-a):${RESET} "
read -r ZONE
export ZONE
export REGION=${ZONE%-*}

log_step "Configuring project settings..."
gcloud auth list
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_ID=$DEVSHELL_PROJECT_ID
gcloud config set compute/zone "$ZONE"
gcloud config set compute/region "$REGION"

# --- Network Configuration ---
log_section "NETWORK CONFIGURATION"

log_step "Creating VPC networks and subnets..."
gcloud compute networks create griffin-dev-vpc --subnet-mode custom
gcloud compute networks subnets create griffin-dev-wp --region=$REGION --range=192.168.16.0/20 --network=griffin-dev-vpc
gcloud compute networks subnets create griffin-dev-mgmt --region=$REGION --network=griffin-dev-vpc --range=192.168.32.0/20

log_step "Downloading deployment manager configuration..."
gsutil cp -r gs://cloud-training/gsp321/dm .
cd dm || exit
sed -i s/SET_REGION/$REGION/g prod-network.yaml

log_step "Deploying production network..."
gcloud deployment-manager deployments create prod-network --config=prod-network.yaml
cd ..

# --- Bastion Host Setup ---
log_section "BASTION HOST SETUP"

log_step "Creating bastion host and firewall rules..."
gcloud compute instances create bastion --zone=$ZONE \
    --network-interface=network=griffin-dev-vpc,subnet=griffin-dev-mgmt \
    --network-interface=network=griffin-prod-vpc,subnet=griffin-prod-mgmt \
    --tags=ssh

gcloud compute firewall-rules create fw-ssh-dev --target-tags ssh --allow=tcp:22 --network=griffin-dev-vpc --source-ranges=0.0.0.0/0
gcloud compute firewall-rules create fw-ssh-prod --target-tags ssh --allow=tcp:22 --network=griffin-prod-vpc --source-ranges=0.0.0.0/0

# --- Database Setup ---
log_section "DATABASE SETUP"

log_step "Creating Cloud SQL instance..."
gcloud sql instances create griffin-dev-db --region=$REGION --database-version=MYSQL_5_7 --root-password="password123"

log_step "Configuring WordPress database..."
gcloud sql databases create wordpress --instance=griffin-dev-db
gcloud sql users create wp_user --instance=griffin-dev-db --password="securepassword"
gcloud sql users list --instance=griffin-dev-db --format="value(name)" --filter="host='%'"

# --- Kubernetes Cluster Setup ---
log_section "KUBERNETES CLUSTER SETUP"

log_step "Creating GKE cluster..."
gcloud container clusters create griffin-dev --zone=$ZONE \
    --machine-type e2-standard-4 \
    --network griffin-dev-vpc \
    --subnetwork griffin-dev-wp \
    --num-nodes 2

gcloud container clusters get-credentials griffin-dev --zone=$ZONE

log_step "Downloading Kubernetes configurations..."
cd ~/ || exit
gsutil cp -r gs://cloud-training/gsp321/wp-k8s .

# --- WordPress Deployment ---
log_section "WORDPRESS DEPLOYMENT"

log_step "Creating Kubernetes resources..."
cat > wp-k8s/wp-env.yaml <<EOF
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: wordpress-volumeclaim
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 200Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: database
type: Opaque
stringData:
  username: wp_user
  password: securepassword
EOF

cd wp-k8s || exit
kubectl create -f wp-env.yaml

log_step "Creating service account credentials..."
gcloud iam service-accounts keys create key.json \
    --iam-account=cloud-sql-proxy@$GOOGLE_CLOUD_PROJECT.iam.gserviceaccount.com
kubectl create secret generic cloudsql-instance-credentials --from-file key.json

INSTANCE_ID=$(gcloud sql instances describe griffin-dev-db --format='value(connectionName)')

log_step "Deploying WordPress..."
cat > wp-deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress
  labels:
    app: wordpress
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wordpress
  template:
    metadata:
      labels:
        app: wordpress
    spec:
      containers:
        - image: wordpress
          name: wordpress
          env:
          - name: WORDPRESS_DB_HOST
            value: 127.0.0.1:3306
          - name: WORDPRESS_DB_USER
            valueFrom:
              secretKeyRef:
                name: database
                key: username
          - name: WORDPRESS_DB_PASSWORD
            valueFrom:
              secretKeyRef:
                name: database
                key: password
          ports:
            - containerPort: 80
              name: wordpress
          volumeMounts:
            - name: wordpress-persistent-storage
              mountPath: /var/www/html
        - name: cloudsql-proxy
          image: gcr.io/cloudsql-docker/gce-proxy:1.33.2
          command: ["/cloud_sql_proxy",
                    "-instances=$INSTANCE_ID=tcp:3306",
                    "-credential_file=/secrets/cloudsql/key.json"]
          securityContext:
            runAsUser: 2
            allowPrivilegeEscalation: false
          volumeMounts:
            - name: cloudsql-instance-credentials
              mountPath: /secrets/cloudsql
              readOnly: true
      volumes:
        - name: wordpress-persistent-storage
          persistentVolumeClaim:
            claimName: wordpress-volumeclaim
        - name: cloudsql-instance-credentials
          secret:
            secretName: cloudsql-instance-credentials
EOF

kubectl create -f wp-deployment.yaml
kubectl create -f wp-service.yaml

# --- User Permissions ---
log_section "USER PERMISSIONS"

log_step "Updating user permissions..."
IAM_POLICY_JSON=$(gcloud projects get-iam-policy "$DEVSHELL_PROJECT_ID" --format=json)
USERS=$(echo "$IAM_POLICY_JSON" | jq -r '.bindings[] | select(.role == "roles/viewer").members[]')

for USER in $USERS; do
  if [[ $USER == *"user:"* ]]; then
    USER_EMAIL=$(echo "$USER" | cut -d':' -f2)
    gcloud projects add-iam-policy-binding "$DEVSHELL_PROJECT_ID" \
      --member="user:$USER_EMAIL" \
      --role=roles/editor
  fi
done

# --- Monitoring Setup ---
log_section "MONITORING SETUP"

log_step "Waiting for WordPress service to be ready (60s)..."
sleep 60

EXTERNAL_IP=$(kubectl get services wordpress -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')

log_step "Configuring uptime monitoring..."
cat > terraform.tfvars <<EOF
project_id = "$DEVSHELL_PROJECT_ID"
external_ip = "$EXTERNAL_IP"
EOF

cat > monitoring.tf <<EOF
variable "project_id" {
  description = "The project ID"
}

variable "external_ip" {
  description = "The external IP address"
}

provider "google" {
  project = var.project_id
}

resource "google_monitoring_uptime_check_config" "wordpress_uptime" {
  display_name = "wordpress-uptime-check"
  timeout      = "60s"

  http_check {
    port           = "80"
    request_method = "GET"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.external_ip
    }
  }

  checker_type = "STATIC_IP_CHECKERS"
}
EOF

terraform init
terraform apply --auto-approve

# --- Completion Footer ---
echo
echo -e "${GREEN}${BOLD}┌──────────────────────────────────────────────────────────────────┐"
echo -e "│                   COMPLETED SUCCESSFULLY!                    │"
echo -e "└──────────────────────────────────────────────────────────────────┘${RESET}"
