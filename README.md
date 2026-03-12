# Data API Builder (DAB) with SQL in Microsoft Fabric

Deploy a [Data API Builder](https://learn.microsoft.com/en-us/azure/data-api-builder/) container that connects to a SQL database in Microsoft Fabric using Azure AD authentication.

## Problem

The official DAB container image (`mcr.microsoft.com/azure-databases/data-api-builder`) does not include the Azure CLI. When using `Authentication=Active Directory Default` in the connection string, `DefaultAzureCredential` cannot find any credential provider inside the container, causing authentication to fail.

This is the root cause of [microsoft/vscode-mssql#21517](https://github.com/microsoft/vscode-mssql/issues/21517).

## Solution

Build a custom DAB image that includes the Azure CLI, then mount the host's `~/.azure` directory into the container so `AzureCliCredential` can use the cached login session.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed on the host
- An Azure AD account with access to your Fabric SQL database

## Quick Start

### 1. Login to Azure

```bash
az login
```

### 2. Update the connection string

Edit `dab-config.json` and replace the placeholders in the connection string:

```
Server=tcp:<your-server>.<org-name>-database.fabric.microsoft.com,1433;Initial Catalog=<your-database>;...
```

You can find your server and database names in the Fabric portal under your SQL database's connection strings.

### 3. Build the custom DAB image

```bash
docker build -t dab-fabric .
```

> **Apple Silicon (M1/M2):** Add the `--platform linux/amd64` flag since the DAB image is AMD64 only:
> ```bash
> docker build --platform linux/amd64 -t dab-fabric .
> ```

### 4. Run the container

```bash
docker run -d --name dab-fabric -p 5001:5000 \
  -v ~/.azure:/root/.azure \
  -v $(pwd)/dab-config.json:/App/dab-config.json \
  -u root \
  dab-fabric
```

> **Apple Silicon:** Add `--platform linux/amd64` after `docker run -d`.

Key flags explained:
| Flag | Purpose |
|------|---------|
| `-v ~/.azure:/root/.azure` | Mounts Azure CLI credentials into the container |
| `-u root` | Required so `az` CLI can write to its cache files |
| `-p 5001:5000` | Maps container port 5000 to host port 5001 (port 5000 is often used by AirPlay on macOS) |

### 5. Verify

```bash
# Check logs
docker logs -f dab-fabric

# Test the API
curl -s http://localhost:5001/api/table-name | jq
```

## Alternative: Run DAB CLI directly (no Docker)

If you prefer to skip Docker entirely, install the DAB CLI and run it on the host where `az login` credentials are directly available:

```bash
# Install DAB CLI (requires .NET 8 SDK)
dotnet tool install -g Microsoft.DataApiBuilder

# Run
dab start -c dab-config.json
```

## Connection String Reference

The connection string uses [Microsoft.Data.SqlClient](https://learn.microsoft.com/en-us/dotnet/api/microsoft.data.sqlclient.sqlconnection.connectionstring) format:

| Property | Value | Description |
|----------|-------|-------------|
| `Server` | `tcp:<server>,1433` | Fabric SQL endpoint with protocol prefix |
| `Initial Catalog` | `<database-name>` | Database name (includes GUID in Fabric) |
| `Encrypt` | `True` | Required for Fabric |
| `TrustServerCertificate` | `False` | Validates the server certificate |
| `Connection Timeout` | `30` | Seconds to wait for connection |
| `Authentication` | `Active Directory Default` | Uses [DefaultAzureCredential](https://learn.microsoft.com/en-us/dotnet/api/azure.identity.defaultazurecredential) |

`Active Directory Default` tries credential providers in this order:
1. Environment variables (`AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`)
2. Workload Identity
3. Managed Identity
4. Visual Studio Token Provider
5. **Azure CLI** (this is what we use)
6. PowerShell
7. Azure Developer CLI

## DAB Configuration

The `dab-config.json` exposes the `dbo.table-name` table as a read-only REST endpoint at `/api/table-name`. To add more entities or enable GraphQL/MCP, see the [DAB configuration docs](https://learn.microsoft.com/en-us/azure/data-api-builder/configuration/).

## Why Not Managed Identity?

DAB's documentation describes two Managed Identity options for authentication:

- **User-Assigned Managed Identity (UAMI):** `Authentication=Active Directory Managed Identity; User Id=<UMI_CLIENT_ID>;`
- **System-Assigned Managed Identity (SAMI):** `Authentication=Active Directory Managed Identity;`

Neither of these work when running DAB locally (Docker, Codespaces, or bare metal). Managed Identity authentication relies on the [Azure Instance Metadata Service (IMDS)](https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service) endpoint at `169.254.169.254`, which is **only available inside Azure compute resources** (App Service, Container Apps, AKS, Azure VMs, etc.).

When running outside Azure, the IMDS endpoint is unreachable and authentication fails with:

```
ManagedIdentityCredential authentication unavailable.
No response received from the managed identity endpoint.
```

This includes Fabric Workspace Identities — even though Fabric assigns an identity to your workspace (visible in Workspace Settings > Workspace Identity), that identity can only be assumed by services running within Fabric infrastructure, not by external containers.

**Bottom line:** For local development, CI/CD pipelines, or any non-Azure environment, use `Active Directory Default` with Azure CLI credentials (this repo's approach) or a Service Principal.

## Why a Custom Dockerfile?

The base DAB container image is built on [CBL-Mariner 2.0](https://github.com/microsoft/CBL-Mariner) (Microsoft's lightweight Linux distro). It does not include the Azure CLI, which means `DefaultAzureCredential` exhausts all credential providers and fails with:

```
Azure CLI not installed
```

The custom Dockerfile installs `azure-cli` using Mariner's package manager (`tdnf`), adding ~460MB to the image. This enables the `AzureCliCredential` path in the `DefaultAzureCredential` chain.

## Cleanup

```bash
docker rm -f dab-fabric
docker rmi dab-fabric
```

