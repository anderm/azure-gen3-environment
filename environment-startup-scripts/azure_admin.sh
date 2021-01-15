#!/bin/bash

declare PRODUCT_NAME=gen3
declare RESOURCE_SCOPE=infra

printf "\
   __   ____  _  _  ____  ____    ____  __ _  _  _ 
  / _\ (__  )/ )( \(  _ \(  __)  (  __)(  ( \/ )( \ 
 /    \ / _/ ) \/ ( )   / ) _)    ) _) /    /\ \/ / 
 \_/\_/(____)\____/(__\_)(____)  (____)\_)__) \__/ 
====================================================
Note: this is the initial admin script for a Gen3 environment on Azure

!!!!!!!!!!!!!!!!!!!! NOTICE !!!!!!!!!!!!!!!!!!!!
This script is idempotent. 
However, the first time you run it, you will see a lot of errors checking for existance of (non-existant) resources.
This is normal, as long as the script does not exit early.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n"

printf "What is the environment name? alphanumeric characters only (eg. dev).\n\n"
# prompt the user for the name of the environment. Should be unique, 3-10 characters, alphanumeric, all lower case
read ENVIRONMENT
ENVIRONMENT=${ENVIRONMENT}

printf "Setting up Service Principal now...\n\n"
# create service principal name
SP_NAME=http://sp-${PRODUCT_NAME}-${RESOURCE_SCOPE}-${ENVIRONMENT}
export KV_NAME=kv-${PRODUCT_NAME}-${RESOURCE_SCOPE}-${ENVIRONMENT}

# Check if client secret exists in key vault. If not, create new service principal or allow Azure to 
# patch existing service principal with updated password.
printf "Checking for existing Service Principal ...\n\n"
if ! az keyvault secret show --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-APP-SECRET" --query name -o tsv; then
    # create service principal; store password
    printf "Creating Service Principal and storing client secret...\n\n"
    CLIENT_SECRET=$(az ad sp create-for-rbac -n ${SP_NAME} --query password -o tsv)
else
    CLIENT_SECRET=$(az keyvault secret show --vault-name ${KV_NAME} --name "SERVICE-PRINCIPAL-APP-SECRET" --query value -o tsv)
    echo "Retrieving client secret from key vault."
fi

if [[ -z $CLIENT_SECRET ]]
then
  echo "ERROR: failed to create the service principal"
  exit 1
fi

# retrieve service principal id
CLIENT_ID=$(az ad sp show --id ${SP_NAME} --query appId -o tsv)

if [[ -z $CLIENT_ID ]]
then
  echo "ERROR: failed to retrieve the service principal id"
  exit 1
fi

# retrieve subscription id
SUBSCR_ID=$(az account show -o tsv --query id)
# retrieve tenant id
TENANT_ID=$(az account show -o tsv --query tenantId)

printf "Creating Resource Group...\n\n"
# create pipeline resource group
if [ -z $LOCATION ]
then
  export LOCATION=eastus
fi

export PIPELINE_RG_NAME=rg-${PRODUCT_NAME}-${RESOURCE_SCOPE}-${ENVIRONMENT}
echo "Checking if resource group ${PIPELINE_RG_NAME} exists with location ${LOCATION}."
if [[ -n ${PIPELINE_RG_NAME} ]] && [[ -n ${LOCATION} ]]; then
    if az group show -n ${PIPELINE_RG_NAME} --query name -o tsv; then
        LOCATION=$(az group show -n ${PIPELINE_RG_NAME} --query location -o tsv)
        printf "Using existing resource group: ${PIPELINE_RG_NAME} in ${LOCATION}.\n\n"
    elif ! az group create --name ${PIPELINE_RG_NAME} --location ${LOCATION} -o table; then
        echo "ERROR: Failed to create the resource group."
        exit 1
    else
        printf "Created resource group: ${PIPELINE_RG_NAME} in ${LOCATION}.\n\n"
    fi
fi

printf "Setting up Key Vault now...\n\n"
echo "Checking if key vault ${KV_NAME} already exists."

if [[ -n ${KV_NAME} ]]; then
    if az keyvault show --name ${KV_NAME} --resource-group ${PIPELINE_RG_NAME} --query name -o tsv; then
        printf "Using existing key vault: ${KV_NAME}.\n\n"
    elif ! az keyvault create --name ${KV_NAME} --resource-group ${PIPELINE_RG_NAME} -o table; then
        echo "ERROR: Failed to create key vault."
        exit 1
    else
        printf "Key vault created.\n\n"
    fi
fi

printf "Assigning read access for the service to key vault via access policy...\n\n"
az keyvault set-policy --name ${KV_NAME}  --spn ${SP_NAME} --secret-permissions get list \
--key-permissions get list --certificate-permissions get list --subscription ${SUBSCR_ID}

printf "Creating Terraform Backend Storage Account...\n\n"
export TFSA_NAME=st${PRODUCT_NAME}${RESOURCE_SCOPE}${ENVIRONMENT}
echo "Checking if storage account ${TFSA_NAME} already exists"
if [[ -n ${SUBSCR_ID} ]]; then
    if az storage account show --name ${TFSA_NAME} --resource-group ${PIPELINE_RG_NAME} --query name -o tsv; then
        printf "Using existing storage account: ${TFSA_NAME}.\n\n"
    elif ! az storage account create --resource-group ${PIPELINE_RG_NAME} --name ${TFSA_NAME} --sku Standard_LRS --encryption-services blob -o table; then
        echo "ERROR: Failed to create storage account."
        exit 1
    else
        printf "Pipeline Storage Account created. Name = ${TFSA_NAME}.\n\n"
    fi
fi

# retrieve storage account access key
if [[ -n ${PIPELINE_RG_NAME} ]]; then
    if ! ARM_ACCESS_KEY=$(az storage account keys list --resource-group $PIPELINE_RG_NAME --account-name $TFSA_NAME --query [0].value -o tsv); then
        echo "ERROR: Failed to Retrieve Storage Account Access Key."
        exit 1
    fi
    printf "Pipeline Storage Account Access Key = ${ARM_ACCESS_KEY}.\n\n"
fi

# create storage container
if [[ -n ${PIPELINE_RG_NAME} ]]; then
    if ! az storage container create --name "container${TFSA_NAME}" --public-access off --account-name $TFSA_NAME --account-key $ARM_ACCESS_KEY -o table; then
        echo "ERROR: Failed to Retrieve Storage Container."
        exit 1
    fi
    echo "TF State Storage Account Container created."
    export TFSA_CONTAINER=$(az storage container show --name "container${TFSA_NAME}" --account-name ${TFSA_NAME} --account-key ${ARM_ACCESS_KEY} --query name -o tsv)
    echo "TF Storage Container name = ${TFSA_CONTAINER}"
fi


## KEYVAULT SECRETS ##

# service principal variables
if ! az keyvault secret show --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-SUB-ID" --query name -o tsv; then
    az keyvault secret set -o table --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-SUB-ID"     --value $SUBSCR_ID
else
    printf "SERVICE-PRINCIPAL-SUB-ID already exists in key vault.\n\n"
fi

if ! az keyvault secret show --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-TENANT-ID" --query name -o tsv; then
    az keyvault secret set -o table --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-TENANT-ID"  --value $TENANT_ID
else
    printf "SERVICE-PRINCIPAL-TENANT-ID already exists in key vault.\n\n"
fi

if ! az keyvault secret show --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-APP-ID" --query name -o tsv; then
    az keyvault secret set -o table --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-APP-ID"     --value $CLIENT_ID
else
    printf "SERVICE-PRINCIPAL-APP-ID already exists in key vault.\n\n"
fi

if ! az keyvault secret show --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-APP-SECRET" --query name -o tsv; then
    az keyvault secret set -o table --vault-name $KV_NAME --name "SERVICE-PRINCIPAL-APP-SECRET" --value $CLIENT_SECRET
else
    printf "SERVICE-PRINCIPAL-APP-SECRET already exists in key vault.\n\n"
fi

# storage variables
az keyvault secret set -o table --vault-name $KV_NAME --name "BACKEND-STORAGE-ACCOUNT-NAME"             --value $TFSA_NAME
az keyvault secret set -o table --vault-name $KV_NAME --name "BACKEND-STORAGE-ACCOUNT-CONTAINER-NAME"   --value $TFSA_CONTAINER
az keyvault secret set -o table --vault-name $KV_NAME --name "BACKEND-ACCESS-KEY"                       --value $ARM_ACCESS_KEY
az keyvault secret set -o table --vault-name $KV_NAME --name "BACKEND-KEY"                              --value "${ENVIRONMENT}.terraform.tfstate"

# other variables
if ! az keyvault secret show --vault-name $KV_NAME --name "PRODUCT-NAME" --query name -o tsv; then
    az keyvault secret set -o table --vault-name $KV_NAME --name "PRODUCT-NAME"   --value $PRODUCT_NAME
else
    printf "PRODUCT-NAME already exists in key vault.\n\n"
fi

if ! az keyvault secret show --vault-name $KV_NAME --name "LOCATION" --query name -o tsv; then
    az keyvault secret set -o table --vault-name $KV_NAME --name "LOCATION" --value $LOCATION
else
    printf "LOCATION already exists in key vault.\n\n"
fi

if ! az keyvault secret show --vault-name $KV_NAME --name "RG-NAME" --query name -o tsv; then
    az keyvault secret set -o table --vault-name $KV_NAME --name "RG-NAME"  --value $PIPELINE_RG_NAME
else
    printf "RG-NAME already exists in key vault.\n\n"
fi

if ! az keyvault secret show --vault-name $KV_NAME --name "INFRA-KV-NAME" --query name -o tsv; then
    az keyvault secret set -o table --vault-name $KV_NAME --name "INFRA-KV-NAME"  --value $KV_NAME
else
    printf "INFRA-KV-NAME already exists in key vault.\n\n"
fi

# generate RSA keys
printf "Checking for RSA key in key vault...\n\n"
if ! az keyvault secret show --vault-name $KV_NAME --name "AKS-CLUSTER-PUBLIC-KEY" --query name -o tsv; then
    printf "Generating RSA Key...\n\n"
    ssh-keygen -f ./sftp -t rsa -b 4096 -N ""
    az keyvault secret set --vault-name ${KV_NAME} -n "AKS-CLUSTER-PRIVATE-KEY" -f './sftp'
    az keyvault secret set --vault-name ${KV_NAME} -n "AKS-CLUSTER-PUBLIC-KEY" -f './sftp.pub'
else
    printf "RSA keys already exist in key vault.\n\n"
fi

rm -f ./sftp
rm -f ./sftp.pub

printf "Azure Admin Script is done.\n"
