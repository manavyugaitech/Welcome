#!/bin/bash
# Define color variables

BLACK=`tput setaf 0`
RED=`tput setaf 1`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`
BLUE=`tput setaf 4`
MAGENTA=`tput setaf 5`
CYAN=`tput setaf 6`
WHITE=`tput setaf 7`

BG_BLACK=`tput setab 0`
BG_RED=`tput setab 1`
BG_GREEN=`tput setab 2`
BG_YELLOW=`tput setab 3`
BG_BLUE=`tput setab 4`
BG_MAGENTA=`tput setab 5`
BG_CYAN=`tput setab 6`
BG_WHITE=`tput setab 7`

BOLD=`tput bold`
RESET=`tput sgr0`

#----------------------------------------------------manual input-------------------------------------------#

echo -e "\n${BG_BLUE}${WHITE}${BOLD} CONFIGURATION ${RESET} ${BLUE}${BOLD}Please enter the required environment variables:${RESET}\n"

read -p "${CYAN}Enter IAP_NET_TAG: ${RESET}" IAP_NET_TAG
read -p "${CYAN}Enter INT_NET_TAG: ${RESET}" INT_NET_TAG
read -p "${CYAN}Enter HTTP_NET_TAG: ${RESET}" HTTP_NET_TAG
read -p "${CYAN}Enter ZONE: ${RESET}" ZONE

export IAP_NET_TAG
export INT_NET_TAG
export HTTP_NET_TAG
export ZONE

# Validate inputs
if [ -z "$IAP_NET_TAG" ] || [ -z "$INT_NET_TAG" ] || [ -z "$HTTP_NET_TAG" ] || [ -z "$ZONE" ]; then
    echo -e "\n${BG_RED}${WHITE}${BOLD} ERROR ${RESET} ${RED}One or more variables were left empty. Aborting script.${RESET}\n"
    exit 1
fi

#----------------------------------------------------start--------------------------------------------------#

echo -e "\n${BG_CYAN}${BLACK}${BOLD} INFO ${RESET} ${CYAN}${BOLD}Starting GCP Network & Firewall Configuration Execution...${RESET}\n"

echo "${CYAN}[1/7]${RESET} Deleting open-access firewall rule..."
gcloud compute firewall-rules delete open-access --quiet

echo "${CYAN}[2/7]${RESET} Starting bastion instance..."
gcloud compute instances start bastion \
    --project=$DEVSHELL_PROJECT_ID \
    --zone=$ZONE

echo "${CYAN}[3/7]${RESET} Creating ssh-ingress firewall rule..."
gcloud compute firewall-rules create ssh-ingress --allow=tcp:22 --source-ranges 35.235.240.0/20 --target-tags $IAP_NET_TAG --network acme-vpc

echo "${CYAN}[4/7]${RESET} Tagging bastion instance..."
gcloud compute instances add-tags bastion --tags=$IAP_NET_TAG --zone=$ZONE

echo "${CYAN}[5/7]${RESET} Creating http-ingress firewall rule..."
gcloud compute firewall-rules create http-ingress --allow=tcp:80 --source-ranges 0.0.0.0/0 --target-tags $HTTP_NET_TAG --network acme-vpc

echo "${CYAN}[6/7]${RESET} Tagging juice-shop instance (HTTP)..."
gcloud compute instances add-tags juice-shop --tags=$HTTP_NET_TAG --zone=$ZONE

echo "${CYAN}[7/7]${RESET} Creating internal-ssh-ingress rule & tagging juice-shop..."
gcloud compute firewall-rules create internal-ssh-ingress --allow=tcp:22 --source-ranges 192.168.10.0/24 --target-tags $INT_NET_TAG --network acme-vpc

gcloud compute instances add-tags juice-shop --tags=$INT_NET_TAG --zone=$ZONE

echo -e "\n${YELLOW}⏳ Waiting 30 seconds for network interfaces to stabilize...${RESET}"
sleep 30

cat > prepare_disk.sh <<'EOF_END'

export ZONE=$(gcloud compute instances list juice-shop --format 'csv[no-heading](zone)')

gcloud compute ssh juice-shop --internal-ip --zone=$ZONE --quiet

EOF_END

gcloud compute scp prepare_disk.sh bastion:/tmp --project=$DEVSHELL_PROJECT_ID --zone=$ZONE --quiet

gcloud compute ssh bastion --project=$DEVSHELL_PROJECT_ID --zone=$ZONE --quiet --command="bash /tmp/prepare_disk.sh"

echo "${RED}${BOLD}Congratulations${RESET}" "${WHITE}${BOLD}for${RESET}" "${GREEN}${BOLD}Completing the Lab !!!${RESET}"

#-----------------------------------------------------end----------------------------------------------------------#
