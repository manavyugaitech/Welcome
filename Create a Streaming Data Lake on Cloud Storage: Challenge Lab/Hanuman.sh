#!/bin/bash

# Visual styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}===============================================${NC}"
echo -e "${YELLOW}       MANAVYUG AI KO SUBSCRIBE KARO           ${NC}"
echo -e "${YELLOW}===============================================${NC}"

# Auto-detect Project ID
PROJECT_ID=$(gcloud config get-value project)
echo -e "${GREEN}Detected Project ID:${NC} $PROJECT_ID"

if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}Error: Project ID auto-detect nahi ho paya. Make sure gcloud authenticated hai.${NC}"
    exit 1
fi

# User Inputs
read -p "Enter Region (e.g. us-east1): " LOCATION
read -p "Enter Zone (e.g. us-east1-c): " ZONE
read -p "Enter Pub/Sub Topic Name (e.g. mypubsub): " TOPIC_NAME
read -p "Enter Message Body (e.g. Hello Google!): " MESSAGE
read -p "Enter BigQuery Dataset Name: " DATASET_NAME
read -p "Enter BigQuery Table Name: " TABLE_NAME

# Set Environment Variables
BUCKET_NAME="${PROJECT_ID}-bucket"
JOB_NAME="pubsub-to-gcs-$(date +%s)"

echo -e "\n${YELLOW}Setting gcloud configurations...${NC}"
gcloud config set compute/region "$LOCATION"
gcloud config set compute/zone "$ZONE"

# Task 1: Create a Pub/Sub Topic
echo -e "\n${YELLOW}[Task 1] Creating Pub/Sub Topic: $TOPIC_NAME ...${NC}"
gcloud pubsub topics create "$TOPIC_NAME"

# Task 2: Create App Engine App and Cloud Scheduler Job
echo -e "\n${YELLOW}[Task 2] Setting up Cloud Scheduler...${NC}"
gcloud app create --region="$LOCATION" --quiet || echo "App Engine app pehle se exist kar sakta hai."

gcloud scheduler jobs create pubsub my-scheduler-job \
    --schedule="* * * * *" \
    --topic="$TOPIC_NAME" \
    --message-body="$MESSAGE" \
    --location="$LOCATION"

gcloud scheduler jobs run my-scheduler-job --location="$LOCATION"

# Task 3: Create Cloud Storage Bucket
echo -e "\n${YELLOW}[Task 3] Creating Cloud Storage Bucket: $BUCKET_NAME ...${NC}"
gsutil mb -l "$LOCATION" "gs://$BUCKET_NAME"

# Task 4: Run Dataflow Pipeline
echo -e "\n${YELLOW}[Task 4] Cloning samples and launching Dataflow job...${NC}"
git clone https://github.com/GoogleCloudPlatform/python-docs-samples.git
cd python-docs-samples/pubsub/streaming-analytics || exit

# Create python virtual environment & install requirements
python3 -m venv env
source env/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Launching Dataflow Flex Template / Pipeline
echo -e "${YELLOW}Starting Streaming Dataflow Job...${NC}"
python3 PubSubToGCS.py \
    --project="$PROJECT_ID" \
    --region="$LOCATION" \
    --input_topic="projects/$PROJECT_ID/topics/$TOPIC_NAME" \
    --output_path="gs://$BUCKET_NAME/samples/output" \
    --runner="DataflowRunner" \
    --temp_location="gs://$BUCKET_NAME/temp" \
    --window_size=2 \
    --worker_disk_type="pd-standard" \
    --worker_machine_type="e2-standard-2" \
    --zone="$ZONE" &

echo -e "\n${GREEN}===============================================${NC}"
echo -e "${GREEN}                              Successfully!      ${NC}"
echo -e "${GREEN} Lab verification status check karein.         ${NC}"
echo -e "${GREEN}===============================================${NC}"
