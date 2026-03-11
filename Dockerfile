FROM mcr.microsoft.com/azure-databases/data-api-builder:latest

USER root

# Install Azure CLI so DefaultAzureCredential can use AzureCliCredential.
# The base DAB image (CBL-Mariner 2.0) does not include az CLI, which means
# Active Directory Default authentication fails inside the container.
RUN tdnf install -y azure-cli && tdnf clean all

