
# Build a Secure Google Cloud Network: Challenge Lab   [GSP322](https://www.skills.google/games/7445/labs/45636)

<blockquote style="background-color: #1e1e2e; color: #cdd6f4; border-left: 5px solid #89b4fa; border-radius: 8px; padding: 1.2em; font-family: sans-serif; font-size: 14px; line-height: 1.6; box-shadow: 0 4px 6px rgba(0,0,0,0.3);">
  <div style="color: #89b4fa; font-weight: bold; font-size: 16px; margin-bottom: 8px;">
    ℹ️ DISCLAIMER
  </div>
  <strong style="color: #f9e2af;">Educational Purpose Only:</strong> This script and guide are provided for educational purposes to help you understand lab services and boost your career. Please review the script before use to familiarize yourself with Google Cloud services.
  <br><br>
  <strong style="color: #f9e2af;">Terms Compliance:</strong> Always ensure compliance with Qwiklabs' terms of service and YouTube's community guidelines. The goal is to enhance your learning experience — not to circumvent it.
</blockquote>

# Step 1:
```
export IAP_NETWORK_TAG=
export INTERNAL_NETWORK_TAG=
export HTTP_NETWORK_TAG=
export ZONE=
```
# Step 2:

```
gcloud compute firewall-rules delete open-access
gcloud compute firewall-rules create ssh-ingress --allow=tcp:22 --source-ranges 35.235.240.0/20 --target-tags $IAP_NETWORK_TAG --network acme-vpc
gcloud compute instances add-tags bastion --tags=$IAP_NETWORK_TAG --zone=$ZONE
gcloud compute firewall-rules create http-ingress --allow=tcp:80 --source-ranges 0.0.0.0/0 --target-tags $HTTP_NETWORK_TAG --network acme-vpc 
gcloud compute instances add-tags juice-shop --tags=$HTTP_NETWORK_TAG --zone=$ZONE
gcloud compute firewall-rules create internal-ssh-ingress --allow=tcp:22 --source-ranges 192.168.10.0/24 --target-tags $INTERNAL_NETWORK_TAG --network acme-vpc
gcloud compute instances add-tags juice-shop --tags=$INTERNAL_NETWORK_TAG --zone=$ZONE
```

# Step 3(Run in SHH tab) :

```
gcloud compute ssh juice-shop --internal-ip
```



