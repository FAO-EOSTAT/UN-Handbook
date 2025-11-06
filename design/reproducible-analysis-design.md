# Reproducible Analysis System for UN Handbook - Design Document

**Date**: 2025-11-05
**Status**: Draft
**Author**: Sean Lovell 

## Executive Summary

This document outlines the design for a "reproducible analysis" feature that allows readers to launch any chapter of the UN Handbook into a one-click, pre-configured Kubernetes environment.

- **For Readers**: A "Reproduce this analysis" button launches a JupyterLab session with all code, data, and dependencies ready.
- **For Chapter Authors**: A zero-friction, git-native workflow. Authors push data to a tracked directory, and a CI pipeline automatically builds, versions, and deploys the data artifact.
- **For Infrastructure**: The system leverages Onyxia to dynamically provision ephemeral sessions. This design is stateless, using a CSI image driver to mount OCI data artifacts directly as volumes, and pre-built images for the environment.

**Key Architectural Decisions**:
-  Onyxia-native Orchestration: Use Onyxia for UI, authentication, and service deployment.
-  Stateless Data Layer: Use a CSI Image Driver to mount OCI data artifacts directly as read-only volumes.
-  Implicit Performance: Startup speed (5-15s) is achieved via standard node-level container image caching, which is more robust than managed PVCs.
-  Automated Author Workflow: A fully CI-driven (GitHub Actions) pipeline builds content-hashed (immutable) data artifacts and auto-commits the new hash back to the chapter, ensuring true reproducibility.
-  Portable & Decoupled Auth: Use standard Kubernetes Workload Identity (IRSA) as the primary mechanism for AWS credentials. This makes the core Helm chart portable and not dependent on Onyxia-specific injectors.
-  Curated & Isolated Environments: Start with a "base" Docker image, but the CI pipeline is designed to build chapter-specific compute images (from renv.lock) to prevent future dependency conflicts.

---

## Table of Contents

1. [Current State & Design Goals](#current-state--design-goals)
2. [Design Requirements & Principles](#design-requirements--principles)
3. [Architecture Overview](#architecture-overview)
4. [High-Level User Workflow](#high-level-user-workflow)
5. [Key Architectural Components](#key-architectural-components)
6. [Data Packaging & Storage (CI-Driven)](#data-packaging--storage-ci-driven)
7. [Zero-Config Cloud Access (AWS OIDC)](#zero-config-cloud-access-aws-oidc)
8. [Technical Implementation](#technical-implementation)
9. [Implementation Roadmap](#implementation-roadmap)
10. [Success Metrics](#success-metrics)

---

## Current State & Design Goals

### Current State

The UN Handbook is a Quarto book with 48 chapters. These analyses vary widely in computational load, from light theory chapters to heavy, GPU-based deep learning models. Chapters use R (with renv), some Python, and access both local cached data (RDS files, models) and remote cloud data (STAC catalogs).

**Project Type**: Quarto book for UN Handbook on Remote Sensing for Agricultural Statistics
**Repository**: https://github.com/FAO-EOSTAT/UN-Handbook
**Published**: https://FAO-EOSTAT.github.io/UN-Handbook/

**Content Organization** (48 chapters across 7 parts):
- Part 1: Theory (11 chapters) - Remote sensing fundamentals
- Part 2: Crop Type Mapping (6 chapters) - Poland, Mexico, Zimbabwe, China, Chile, DEA
- Part 3: Crop Yield Estimation (5 chapters) - Finland, Indonesia, Colombia, Poland, China
- Part 4: Crop Statistics (4 chapters) - Area estimation, regression, calibration
- Part 5: UAV Agriculture (4 chapters) - Field identification, crop monitoring
- Part 6: Disaster Response (1 chapter) - Flood monitoring
- Part 7: Additional Topics (2 chapters) - World Cereal, learning resources

### Computational Characteristics

#### Analysis Types by Computational Load

**Light (Theory Chapters)**:
- Educational examples with small datasets
- Code snippets with `eval: false`
- Resource needs: 2-4 CPU, 8GB RAM
- Runtime: Minutes

**Medium (Crop Statistics)**:
- Google Earth Engine data access
- Sample-based area estimators
- Statistical methods
- Resource needs: 4-6 CPU, 16GB RAM
- Runtime: 15-30 minutes

**Heavy (Crop Type Mapping)**:
- Example: Chile chapter
  - Sentinel-2 imagery via STAC
  - 62,920 training points from 4,140 polygons
  - Random Forest classification
  - Self-Organizing Maps
  - 22 RDS files (models, samples, classifications)
- Resource needs: 6-10 CPU, 24-48GB RAM
- Runtime: 1-2 hours

**Very Heavy (Deep Learning)**:
- Example: Colombia chapter (crop yield estimation)
  - Sentinel-1 SAR data processing
  - Deep learning with `luz` (PyTorch for R)
  - Requires GPU for reasonable performance
  - 23 cache entries
- Resource needs: 8+ CPU, 32GB RAM, 1 GPU (8GB VRAM)
- Runtime: 2-4 hours

### Current Technology Stack

#### R Environment
- **R Version**: 4.5.1
- **Package Manager**: `renv` with lock file (7,383 lines, ~427KB)
- **Key Packages**:
  - Geospatial: `sits`, `sf`, `terra`, `stars`, `lwgeom`
  - Cloud Access: `rstac`, `earthdatalogin`, `arrow`, `gdalcubes`
  - Machine Learning: `randomForest`, `ranger`, `e1071`, `kohonen`
  - Deep Learning: `torch`, `luz`
  - Visualization: `ggplot2`, `tmap`, `leaflet`
  - Python Integration: `reticulate` (for Indonesia chapter)

#### Python Environment
- **Status**: One chapter (Indonesia) uses Python via `reticulate`
- **Solution**: Create `requirements.txt` for reproducibility

#### Data Sources

**Cloud Platforms (Remote Access)**:
- Microsoft Planetary Computer (MPC)
- AWS (Sentinel-2 L2A)
- Digital Earth Africa
- Brazil Data Cube (BDC)
- Copernicus Data Space Ecosystem (CDSE)
- NASA HLS (Harmonized Landsat-Sentinel)
- Google Earth Engine

**Local Storage**:
- `/data` directory: 59 MB
- `/etc` directory: 227 MB (cached models and results)
- **Data Types**: RDS files (models, cubes, samples), Shapefiles, Geoparquet, TIFF (gitignored)

**Access Pattern**:
- Preferred: Cloud-native via STAC protocol
- Reality: Many chapters use pre-computed RDS files to avoid re-computation

### Current Reproducibility Status

**Strengths**:
-  `renv` lock file with complete R package snapshot
-  Version control with clear structure
-  Modular design (each chapter independent)
-  Cloud-native workflows using STAC

**Gaps**:
-  No containerization (no Dockerfile)
-  No CI/CD or automated testing
-  Pre-computed results (RDS files suggest incomplete reproducibility)
-  Python dependencies unmanaged
-  System dependencies (GDAL, PROJ, GEOS) versions unspecified
-  Computational requirements undocumented

---

## Design Requirements & Principles

### Key Decisions

1. **Resource Allocation**: Dynamic (auto-scale per chapter based on metadata)
2. **Data Strategy**: Pre-packaged, content-hashed, and immutable OCI artifacts for local data; automatic OIDC-based credentials for live cloud data.
3. **User Interface**: JupyterLab (supports R/Python)
4. **Session Duration**: Ephemeral (e.g., 2-hour auto-cleanup)
5. **Platform Integration**: Orchestrated by Onyxia, but with a portable core
6. **Cloud Access**: Automatic, temporary AWS credentials via standard Kubernetes Workload Identity (IRSA)

### Design Principles

**For Handbook Readers ("User Magic")**:
- One-click experience: Click button → JupyterLab ready
- No setup required: All dependencies pre-configured
- Immediate feedback: Show launch progress and estimated time
- Time-bounded: Clear session expiration with download option

**For Chapter Authors ("Developer Magic")**:
- Simple metadata: Add YAML frontmatter to chapter
- Zero-friction: Just `git push` data files, CI handles the rest
- No Docker or Helm knowledge required
- Version control: Content-hashed snapshots (immutable)

**For Infrastructure**:
- Cost-efficient: Dynamic resources, auto-cleanup
- Scalable: Handle concurrent users
- Observable: Monitoring and usage tracking
- Maintainable: Standard Helm charts, no custom operators
- Secure: Immutable images, no runtime privilege escalation
- Onyxia-native: Leverages existing platform features

---

## Architecture Overview

(See sections 2.3, 2.4, and 3.4 below for detailed technical implementation)

---

## Cloud Data Access Strategy

### Overview: The Dual-Data Architecture

The reproducible analysis system provides seamless access to **two complementary data sources**:

1. **Local Packaged Data** (via CSI Image Driver)
   - Pre-computed models, cached results, reference datasets
   - Content-hashed snapshots for exact reproducibility
   - Fast access (5-15s startup via node-level caching)

2. **Cloud Data Sources** (via automatic AWS credentials)
   - Live satellite imagery from STAC catalogs (Sentinel-2, Landsat, etc.)
   - Cloud-optimized datasets (COG, Zarr, Parquet)
   - Accessed via standard R/Python libraries

**Key Insight**: The system uses **Kubernetes Workload Identity (IRSA)** as the primary mechanism for AWS credentials. This is a standard Kubernetes pattern that makes the Helm chart portable across any cluster with OIDC federation configured. Onyxia's `xOnyxiaContext` provides a fallback path for backward compatibility.

### Primary Mechanism: Workload Identity (IRSA)

**IAM Roles for Service Accounts (IRSA)** is the cloud-native standard for granting AWS permissions to Kubernetes pods. The Helm chart creates a ServiceAccount annotated with an AWS IAM Role ARN. Kubernetes automatically provides a token that the pod's AWS SDK exchanges for credentials.

**How It Works**:

```
1. Onyxia injects IRSA configuration via region.customValues
   ↓
   Helm chart receives: serviceAccount.annotations.eks.amazonaws.com/role-arn
   ↓
2. Chart creates ServiceAccount with IRSA annotation
   ↓
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     annotations:
       eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/handbook-reader
   ↓
3. Kubernetes IRSA webhook injects OIDC token into pod
   ↓
   AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
   AWS_ROLE_ARN=arn:aws:iam::ACCOUNT:role/handbook-reader
   ↓
4. AWS SDK automatically detects IRSA environment
   ↓
   Calls: sts:AssumeRoleWithWebIdentity (no frontend involved)
   ↓
5. Pod receives auto-refreshing AWS credentials
   ↓
   R/Python libraries use them automatically
```

**Benefits**:
-  **Portable**: Works on any Kubernetes cluster with OIDC (EKS, GKE, AKS, self-hosted)
-  **Auto-refresh**: AWS SDK handles credential rotation automatically
-  **Decoupled**: Chart doesn't depend on Onyxia-specific features
-  **Secure**: Short-lived tokens, never stored in config
-  **Standard**: Uses official AWS SDK credential chain

#### Infrastructure Setup (One-Time)

**1. Enable OIDC provider for EKS cluster**:
```bash
eksctl utils associate-iam-oidc-provider --cluster=my-cluster --approve
```

**2. Create IAM role for handbook readers**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::142496269814:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/YOUR_CLUSTER_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "oidc.eks.us-west-2.amazonaws.com/id/YOUR_CLUSTER_ID:sub": "system:serviceaccount:user-*:*"
        }
      }
    }
  ]
}
```

**Or use eksctl** (recommended):
```bash
eksctl create iamserviceaccount \
  --name handbook-reader \
  --namespace default \
  --cluster my-cluster \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve
```

**3. Attach S3 access policy to role**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::sentinel-s2-l2a",
        "arn:aws:s3:::sentinel-s2-l2a/*",
        "arn:aws:s3:::usgs-landsat",
        "arn:aws:s3:::usgs-landsat/*"
      ]
    }
  ]
}
```

**4. Configure Onyxia region with IRSA** (via `region.customValues`):
```yaml
# In Onyxia Helm values or platform configuration
regions:
  - id: "jakarta"
    name: "Jakarta"
    services:
      customValues:
        # IRSA configuration injected into all Helm charts
        serviceAccount:
          create: true
          annotations:
            eks.amazonaws.com/role-arn: "arn:aws:iam::142496269814:role/handbook-reader"
        aws:
          region: "us-west-2"
      defaultConfiguration:
        ipprotection: true      # Enable IP-based access control by default
        networkPolicy: true     # Enable Kubernetes NetworkPolicy by default
```

The `region.customValues` configuration is automatically injected into Helm chart values when services are deployed via Onyxia. This allows region-wide defaults like ServiceAccount annotations for IRSA/Workload Identity to be applied consistently across all deployed services.

**Note on region.customValues**: While fully implemented in Onyxia's codebase, this feature is not yet documented in the official Onyxia region configuration documentation. The implementation allows arbitrary key-value pairs to be injected into all Helm charts via `onyxia.region.customValues`. Charts can access these values using the standard x-onyxia schema pattern:

```json
{
  "serviceAccount": {
    "annotations": {
      "x-onyxia": {
        "overwriteDefaultWith": "region.customValues.serviceAccount.annotations"
      }
    }
  }
}
```

### Fallback Mechanism: xOnyxiaContext (Optional)

For backward compatibility or non-IRSA clusters, Onyxia can inject credentials via `xOnyxiaContext`. The Helm chart supports both mechanisms, with AWS SDK automatically preferring IRSA when available.

**How xOnyxiaContext works** (legacy/fallback path):

```yaml
# Automatically injected by Onyxia
onyxia:
  user:
    idep: "john.doe"
    email: "john.doe@un.org"
    accessToken: "eyJhbGci..."  # Keycloak OIDC token
    refreshToken: "eyJhbGci..."
    # Additional user fields: name, password, ip, darkMode, lang,
    # decodedIdToken, profile
  s3:
    isEnabled: true
    AWS_ACCESS_KEY_ID: "ASIA..."      # ← From AWS STS
    AWS_SECRET_ACCESS_KEY: "..."      # ← From AWS STS
    AWS_SESSION_TOKEN: "..."          # ← From AWS STS
    AWS_DEFAULT_REGION: "us-west-2"
    AWS_BUCKET_NAME: "datalab-142496269814-user-bucket"
    # Additional S3 fields: AWS_S3_ENDPOINT, port, pathStyleAccess,
    # objectNamePrefix, workingDirectoryPath, isAnonymous
  region:
    defaultIpProtection: true
    defaultNetworkPolicy: true
    customValues: {}  # Region-wide custom values
    # Additional region fields: allowedURIPattern, kafka, tolerations,
    # nodeSelector, startupProbe, sliders, resources, openshiftSCC
  k8s:
    domain: "dev.officialstatistics.org"
    randomSubdomain: "123456"
    # Additional k8s fields: ingressClassName, ingress, route, istio,
    # initScriptUrl, useCertManager, certManagerClusterIssuer
  # Optional context sections:
  # - proxyInjection: httpProxyUrl, httpsProxyUrl, noProxy
  # - packageRepositoryInjection: cranProxyUrl, condaProxyUrl, pypiProxyUrl
  # - certificateAuthorityInjection: cacerts, pathToCaBundle
  # - vault: VAULT_ADDR, VAULT_TOKEN, VAULT_MOUNT, VAULT_TOP_DIR
  # - git: name, email, credentials_cache_duration, token
```

Our Helm chart automatically exposes these as environment variables:

```yaml
# templates/deployment.yaml
env:
- name: AWS_ACCESS_KEY_ID
  value: {{ .Values.onyxia.s3.AWS_ACCESS_KEY_ID }}
- name: AWS_SECRET_ACCESS_KEY
  value: {{ .Values.onyxia.s3.AWS_SECRET_ACCESS_KEY }}
- name: AWS_SESSION_TOKEN
  value: {{ .Values.onyxia.s3.AWS_SESSION_TOKEN }}
- name: AWS_DEFAULT_REGION
  value: {{ .Values.onyxia.s3.AWS_DEFAULT_REGION | default "us-west-2" }}
```

### Using Cloud Credentials in Analysis Code

#### R Example: Accessing Sentinel-2 via STAC

```r
# Chapter code (e.g., ct_chile.qmd)
library(rstac)
library(sits)

# AWS credentials automatically detected from environment variables
# No configuration needed!

# Connect to AWS-hosted STAC catalog
s2_catalog <- stac("https://earth-search.aws.element84.com/v1")

# Search for Sentinel-2 imagery
items <- s2_catalog %>%
  stac_search(
    collections = "sentinel-2-l2a",
    bbox = c(-71.5, -33.5, -70.5, -32.5),
    datetime = "2023-01-01/2023-12-31"
  ) %>%
  post_request()

# Create data cube (sits automatically uses AWS credentials)
cube <- sits_cube(
  source = "AWS",
  collection = "SENTINEL-2-L2A",
  tiles = "19HDB",
  bands = c("B02", "B03", "B04", "B08"),
  start_date = "2023-01-01",
  end_date = "2023-12-31"
)

# Access works seamlessly - AWS SDK uses env vars
```

#### Python Example: Accessing Landsat via Arrow

```python
# For chapters using reticulate
import os
import pyarrow.fs as fs

# AWS credentials automatically detected
s3 = fs.S3FileSystem(
    region='us-west-2'
    # access_key_id, secret_access_key, session_token
    # automatically read from environment variables
)

# Read cloud-optimized Parquet file
dataset = pq.ParquetDataset(
    's3://usgs-landsat/collection02/level-2/',
    filesystem=s3
)
```

### Credential Flow Architecture

The system uses **Workload Identity (IRSA)** as the primary mechanism, with xOnyxiaContext as an optional fallback:

```
Primary Flow: IRSA (Workload Identity)
  ├─► ServiceAccount has eks.amazonaws.com/role-arn annotation
  ├─► Kubernetes injects AWS_WEB_IDENTITY_TOKEN_FILE
  ├─► AWS SDK automatically calls sts:AssumeRoleWithWebIdentity
  └─► Pod receives auto-refreshing AWS credentials

Fallback Flow: xOnyxiaContext (Optional)
  ├─► Onyxia frontend calls AWS STS
  ├─► Credentials injected as environment variables
  └─► AWS SDK uses static credentials (12-hour TTL)
```

**Result**: The Helm chart is portable across any Kubernetes cluster with OIDC federation configured.

### Benefits for Reproducible Analysis

1. **No Manual Credential Management**
   - Chapter authors never handle AWS keys
   - No `.aws/credentials` files in containers
   - No secrets to manage in Helm charts

2. **Token Lifecycle**
   - **AWS credentials**: 12 hours (sufficient for most analyses)
   - **OIDC access token**: ~15 minutes (injected at pod creation as static snapshot)
   - **OIDC refresh token**: ~30 days (also injected, but pods don't auto-refresh)
   - **Key insight**: Our analyses primarily use AWS credentials for S3 access, not OIDC tokens
   - **Token refresh**: Onyxia frontend handles refresh, but running pods receive static snapshots
   - **Workaround**: Restart pod for fresh credentials if session exceeds 12 hours

3. **Least Privilege Access**
   - Each user gets credentials scoped to their identity
   - AWS IAM policies control S3 bucket access
   - Audit trail: AWS CloudTrail logs show actual user

4. **Works with Standard Libraries**
   - R: `arrow`, `sits`, `rstac`, `terra`, `sf` all detect AWS credentials automatically
   - Python: `boto3`, `s3fs`, `rasterio` use standard AWS SDK credential chain
   - No custom code needed in analysis scripts

5. **Hybrid Data Strategy**
   - **Fast startup**: Local data from CSI-mounted OCI images (5-15s)
   - **Live data**: Cloud sources via AWS credentials
   - **Reproducibility**: Both data sources version-controlled (content-hashed artifacts + STAC queries in code)

### Example: Complete Analysis Workflow

```r
# ct_chile.qmd - Complete reproducible analysis

library(sits)
library(sf)
library(rstac)

# ============================================================
# Part 1: Load local packaged data (from CSI-mounted OCI image)
# ============================================================

# Pre-trained model from local storage
model <- readRDS("/home/jovyan/handbook-chapter/data/ct_chile/rf_model.rds")

# Reference training data
training_samples <- readRDS("/home/jovyan/handbook-chapter/data/ct_chile/training.rds")

# Region of interest shapefile
roi <- st_read("/home/jovyan/handbook-chapter/data/ct_chile/chile_roi.shp")

# ============================================================
# Part 2: Access live satellite data (from AWS via STAC)
# ============================================================

# AWS credentials automatically available from environment
# No configuration needed!

# Query recent Sentinel-2 imagery
cube <- sits_cube(
  source = "AWS",
  collection = "SENTINEL-2-L2A",
  tiles = "19HDB",
  bands = c("B02", "B03", "B04", "B08"),
  start_date = Sys.Date() - 365,
  end_date = Sys.Date()
)

# ============================================================
# Part 3: Run analysis combining both data sources
# ============================================================

# Classify recent imagery using pre-trained model
classification <- sits_classify(
  data = cube,
  ml_model = model,
  roi = roi,
  output_dir = "/tmp/results"
)

# Compare with reference training data
accuracy <- sits_accuracy(classification, training_samples)

print(accuracy)
```

**Result**: The analysis seamlessly combines:
- Pre-trained model (CSI-mounted data) for reproducibility
- Live satellite data (AWS S3) for up-to-date results
- No credential management code required
- Fully reproducible (content-hashed data, STAC query in code)

### Troubleshooting Cloud Access

If cloud data access fails, users can verify credentials:

```r
# Check AWS credentials are available
Sys.getenv("AWS_ACCESS_KEY_ID")        # Should show ASIA...
Sys.getenv("AWS_SECRET_ACCESS_KEY")    # Should show value
Sys.getenv("AWS_SESSION_TOKEN")        # Should show value

# Test S3 access
library(arrow)
s3_bucket <- s3_bucket("sentinel-s2-l2a")
s3_bucket$ls()  # Should list objects
```

Common issues:
- **Empty credentials**: Pod may have started before Onyxia STS call completed (rare)
- **Expired credentials**: Credentials last 12 hours; restart pod for fresh credentials
- **Wrong IAM policy**: Check AWS role has read access to required S3 buckets

---

## Technical Implementation

### Quarto Extension (Handbook Reader Interface)

**Extension Structure**:
```
_extensions/reproducible-button/
├── _extension.yml
├── reproduce-button.lua (deep-link generator)
└── reproduce-button.js (optional UI enhancements)
```

**Usage in Chapter**:
```yaml
---
title: "Crop Type Mapping - Chile"
reproducible:
  enabled: true
  tier: medium
  image-flavor: base
  data-snapshot: v1.2.3
  estimated-runtime: "20 minutes"
  storage-size: "5Gi"
---

{{< reproduce-button >}}

# Chapter content...
```

**Rendered Output**:
```html
<div class="reproducible-banner">
  <a href="https://datalab.officialstatistics.org/launcher/handbook/chapter-session?autoLaunch=true&chapter.name=ct_chile&chapter.version=v1-2-3&resources.limits.cpu=6000m&resources.limits.memory=24Gi"
     target="_blank"
     class="btn btn-primary">
     Reproduce this analysis
  </a>
  <span class="metadata">
    Resources: Medium (6 CPU, 24GB RAM) |
    Estimated runtime: 20 minutes |
    Session expires after 2 hours
  </span>
</div>
```

**Extension Implementation** (`reproduce-button.lua`):
```lua
-- Quarto filter to inject Onyxia deep-link button

-- Helper function to encode Helm values for Onyxia URLs
local function encode_helm_value(value)
  if value == nil then return "null" end
  if value == true then return "true" end
  if value == false then return "false" end

  -- Convert to string
  local str = tostring(value)

  -- Check if pure number (no units like 'm' or 'Gi')
  if str:match("^%-?%d+%.?%d*$") then
    return str
  end

  -- String values: URL encode and wrap in «»
  local encoded = str:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return "«" .. encoded .. "»"
end

local function build_onyxia_url(meta)
  if not meta.reproducible or not meta.reproducible.enabled then
    return nil
  end

  -- Extract chapter metadata
  local chapter_file = quarto.doc.input_file
  local chapter_name = chapter_file:match("([^/]+)%.qmd$")

  local tier = meta.reproducible.tier or "medium"
  local image_flavor = meta.reproducible["image-flavor"] or "base"
  local data_snapshot = meta.reproducible["data-snapshot"] or "v1.0.0"
  local storage_size = meta.reproducible["storage-size"] or "20Gi"
  local estimated_runtime = meta.reproducible["estimated-runtime"] or "Unknown"

  -- Map resource tier to CPU/memory
  local resource_tiers = {
    light = { cpu = "2000m", memory = "8Gi" },
    medium = { cpu = "6000m", memory = "24Gi" },
    heavy = { cpu = "10000m", memory = "48Gi" },
    gpu = { cpu = "8000m", memory = "32Gi" }
  }
  local resources = resource_tiers[tier]

  -- Map image flavor to repository
  local image_map = {
    base = "ghcr.io/fao-eostat/handbook-base:v1.0",
    gpu = "ghcr.io/fao-eostat/handbook-base-gpu:v1.0"
  }
  local image = image_map[image_flavor]
  local image_repo = image:match("^(.+):") or image
  local image_tag = image:match(":(.+)$") or "v1.0"

  -- Normalize version (dots to hyphens)
  local version_normalized = data_snapshot:gsub("%.", "-")

  -- Build Onyxia deep-link URL
  local base_url = "https://datalab.officialstatistics.org/launcher/handbook/chapter-session"

  local params = {
    "autoLaunch=true",
    "name=" .. encode_helm_value("chapter-" .. chapter_name),

    -- Chapter parameters
    "chapter.name=" .. encode_helm_value(chapter_name),
    "chapter.version=" .. encode_helm_value(version_normalized),
    "chapter.storageSize=" .. encode_helm_value(storage_size),

    -- Image selection
    "image.repository=" .. encode_helm_value(image_repo),
    "image.tag=" .. encode_helm_value(image_tag),

    -- Resources
    "resources.limits.cpu=" .. encode_helm_value(resources.cpu),
    "resources.limits.memory=" .. encode_helm_value(resources.memory),
    "resources.requests.cpu=" .. encode_helm_value(resources.cpu),
    "resources.requests.memory=" .. encode_helm_value(resources.memory),

    -- GPU flag
    "gpu.enabled=" .. (tier == "gpu" and "true" or "false")
  }

  local url = base_url .. "?" .. table.concat(params, "&")
  return url, estimated_runtime
end

function Meta(meta)
  local url, runtime = build_onyxia_url(meta)

  if url then
    -- Create HTML button
    local button_html = string.format([[
<div class="reproducible-banner" style="background: #e3f2fd; padding: 15px; margin: 20px 0; border-radius: 5px;">
  <a href="%s" target="_blank" class="btn btn-primary" style="background: #1976d2; color: white; padding: 10px 20px; text-decoration: none; border-radius: 4px; display: inline-block;">
     Reproduce this analysis
  </a>
  <span class="metadata" style="margin-left: 15px; color: #555;">
    Estimated runtime: %s | Session expires after 2 hours
  </span>
</div>
]], url, runtime)

    -- Prepend button to document
    local button = pandoc.RawBlock('html', button_html)
    table.insert(quarto.doc.body.blocks, 1, button)
  end

  return meta
end
```

---

## Systems Design

### Resource Tier Mapping

```yaml
resource_tiers:
  light:
    cpu: "2"
    memory: "8Gi"
    gpu: 0
    storage: "10Gi"
    use_cases: ["Theory chapters", "Small demonstrations"]

  medium:
    cpu: "6"
    memory: "24Gi"
    gpu: 0
    storage: "20Gi"
    use_cases: ["Crop type mapping", "Random Forest training", "Most case studies"]

  heavy:
    cpu: "10"
    memory: "48Gi"
    gpu: 0
    storage: "50Gi"
    use_cases: ["Large-scale classification", "SAR preprocessing"]

  gpu:
    cpu: "8"
    memory: "32Gi"
    gpu: 1  # NVIDIA with 8GB+ VRAM
    storage: "50Gi"
    use_cases: ["Deep learning (Colombia chapter)", "torch/luz models"]
```

### 2.2 Curated Image Flavors (System Dependencies)

**Problem**: System libraries (GDAL, PROJ, GEOS) cannot be managed by `renv`. Allowing runtime `apt-get install`:
-  Requires `root` access (security vulnerability)
-  Adds 2-5 minutes to startup time
-  Not reproducible (package versions can change)

**Solution**: Pre-built, immutable Docker images maintained by infrastructure team.

**Image Catalog**:

| Image Flavor | Base | System Packages | Use Case |
|--------------|------|-----------------|----------|
| `base` | jupyter/r-notebook:r-4.5.1 | GDAL 3.6.2, PROJ 9.1.1, GEOS 3.11.1 | 95% of chapters |
| `gpu` | nvidia/cuda:12.1-cudnn8 | Same as base + CUDA, cuDNN | Deep learning (Colombia) |

**Author Experience**:
```yaml
reproducible:
  image-flavor: base  # or "gpu"
```

**Helm Chart Integration**:
```yaml
image:
  repository: "ghcr.io/fao-eostat/handbook-base"  # or handbook-base-gpu
  tag: "v1.0"
```

**Adding New System Dependency** (governed process):
1. Author opens GitHub issue requesting new package
2. Infrastructure team reviews and approves
3. PR updates Dockerfile: `apt-get install libmagick++-dev`
4. CI builds new image: `handbook-base:v1.1`
5. Update Helm chart values or Quarto extension
6. Deploy via new handbook render

**Security Benefits**:
-  All system packages installed at build time in trusted CI
-  No `root` access in user containers
-  Immutable, auditable images
-  Versioned (can roll back if needed)

### 2.3 Stateless Data Layer: CSI Image Driver

**Why CSI Image Driver?**
-  **Stateless**: No PVC management, cleanup jobs, or golden PVC coordination
-  **Implicit Performance**: Node-level caching provides 5-15s startup automatically
-  **Simpler**: Kubernetes treats data images like compute images
-  **Immutable**: Each content hash is a unique, reproducible artifact

**How It Works**:

The CSI (Container Storage Interface) Image Driver allows Kubernetes to mount OCI (Docker/container) images directly as volumes. Instead of managing PVCs and DataVolumes, we simply reference the data image in the pod spec:

```yaml
volumes:
- name: chapter-data
  csi:
    driver: csi-image.k8s.io
    volumeAttributes:
      image: "ghcr.io/fao-eostat/handbook-data:ct_chile-sha256-abcdef123"
    readOnly: true
```

When the pod starts:
1. Kubernetes pulls the data image to the node (just like a compute image)
2. The CSI driver mounts the image contents as a read-only filesystem
3. The container sees the data at `/home/jovyan/handbook-chapter/`
4. Node-level caching means subsequent launches are instant (<15s)

**Benefits**:
- **No state management**: No PVCs to create, clone, or clean up
- **Automatic caching**: Kubernetes image cache handles performance
- **Content-addressed**: Each SHA256 hash guarantees exact reproducibility
- **Garbage collection**: Standard Kubernetes image GC removes unused data

### 2.4 CI-Driven Data Packaging with Content Hashing

**Zero-Friction Author Workflow**:

Authors simply commit data files to the repository. A GitHub Actions workflow automatically:

1. **Detects changes** in `data/ct_chile/` or matching patterns
2. **Calculates content hash** (SHA256) of all data files
3. **Builds OCI artifact** with content-hashed tag: `ct_chile-sha256-abcdef123`
4. **Pushes to registry** (GHCR)
5. **Auto-commits hash** back to chapter's `.qmd` frontmatter:
   ```yaml
   reproducible:
     data-snapshot: sha256-abcdef123
   ```

**CI Workflow** (`.github/workflows/package-chapter-data.yml`):

```yaml
name: Package Chapter Data
on:
  push:
    paths:
      - 'data/**'
      - 'etc/*.rds'

jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Detect changed chapters
        id: changes
        run: |
          # Find which chapter data directories changed
          CHANGED_CHAPTERS=$(git diff --name-only HEAD^ HEAD | grep '^data/' | cut -d/ -f2 | sort -u)
          echo "chapters=$CHANGED_CHAPTERS" >> $GITHUB_OUTPUT

      - name: Build and push OCI artifacts
        run: |
          for chapter in ${{ steps.changes.outputs.chapters }}; do
            # Calculate content hash
            HASH=$(find data/$chapter -type f -exec sha256sum {} \; | sort | sha256sum | cut -d' ' -f1 | cut -c1-12)

            # Build OCI image from scratch
            IMAGE="ghcr.io/${{ github.repository_owner }}/handbook-data:${chapter}-sha256-${HASH}"

            docker build -t "$IMAGE" -f- data/$chapter <<EOF
            FROM scratch
            COPY . /data/$chapter/
            LABEL org.opencontainers.image.title="$chapter"
            LABEL org.opencontainers.image.revision="$HASH"
            EOF

            docker push "$IMAGE"

            # Update chapter .qmd file
            yq eval ".reproducible.data-snapshot = \"sha256-$HASH\"" -i ${chapter}.qmd
          done

      - name: Commit updated hashes
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add *.qmd
          git commit -m "chore: update data snapshots [skip ci]"
          git push
```

**Result**: True immutability. The chapter always references an exact, content-addressed data snapshot.

---

## Detailed Implementation

### 3.1 Repository Structure

```
UN-Handbook/
├── _extensions/
│   └── reproducible-button/       # Quarto extension
│       ├── _extension.yml
│       └── reproduce-button.lua   # Deep-link generator
│
├── handbook-catalog/               # Onyxia Helm catalog
│   ├── chapter-session/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── values.schema.json
│   │   └── templates/
│   │       ├── serviceaccount.yaml  # NEW: For IRSA
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       └── ingress.yaml
│   ├── index.yaml                 # Helm repo index
│   └── chapter-session-1.0.0.tgz
│
├── .docker/
│   ├── base.Dockerfile            # R + renv + GDAL
│   ├── gpu.Dockerfile             # CUDA + torch
│   └── .dockerignore
│
├── .github/
│   └── workflows/
│       ├── build-images.yml       # CI: Build compute images
│       ├── package-chapter-data.yml  # CI: Build data artifacts (auto-commits hash)
│       └── generate-metadata.yml  # CI: Scan chapter metadata
│
├── requirements.txt               # Python deps (Indonesia chapter)
│
├── data/
│   ├── ct_chile/                  # Chapter-specific data
│   └── ...
│
└── chapters/
    ├── ct_chile.qmd               # With reproducible: { data-snapshot: sha256-... }
    ├── cy_colombia.qmd
    └── ...
```

### 3.2 Container Images

#### Base Image (`ghcr.io/fao-eostat/handbook-base:v1.0`)

**Dockerfile** (`.docker/base.Dockerfile`):
```dockerfile
FROM jupyter/r-notebook:r-4.5.1

USER root

# Install system dependencies (fixed versions for reproducibility)
RUN apt-get update && apt-get install -y \
    libgdal-dev=3.6.2+dfsg-1~jammy \
    libproj-dev=9.1.1-1~jammy \
    libgeos-dev=3.11.1-1~jammy \
    libudunits2-dev \
    libnode-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

USER ${NB_UID}

# Copy renv files
COPY renv.lock renv.lock
COPY .Rprofile .Rprofile
COPY renv/activate.R renv/activate.R
COPY renv/settings.json renv/settings.json

# Install R packages from renv.lock
RUN R -e "install.packages('renv', repos='https://cloud.r-project.org')"
RUN R -e "renv::restore()"

# Install Python dependencies (for Indonesia chapter)
COPY requirements.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Pre-warm key packages (reduce first-run latency)
RUN R -e "library(sits); library(terra); library(sf)"

# Set working directory
WORKDIR /home/jovyan

# Labels
LABEL org.opencontainers.image.version="v1.0" \
      org.opencontainers.image.title="UN Handbook Base Image" \
      org.opencontainers.image.description="R 4.5.1 + geospatial stack"
```

**Python Requirements** (`requirements.txt`):
```
# For Indonesia chapter (reticulate integration)
numpy>=1.24.0
pandas>=2.0.0
geopandas>=0.13.0
rasterio>=1.3.0
```

#### GPU Image (`ghcr.io/fao-eostat/handbook-base-gpu:v1.0`)

**Dockerfile** (`.docker/gpu.Dockerfile`):
```dockerfile
FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

USER root

# Install R 4.5.1
RUN apt-get update && apt-get install -y \
    software-properties-common \
    && add-apt-repository ppa:c2d4u.team/c2d4u4.0+ \
    && apt-get update && apt-get install -y \
    r-base=4.5.1* \
    r-base-dev=4.5.1* \
    python3 python3-pip \
    libgdal-dev libproj-dev libgeos-dev \
    # ... (same system deps as base)

# Create jovyan user
RUN useradd -m -s /bin/bash -N -u 1000 jovyan
USER jovyan

# Install R packages (same as base)
# ... (copy renv restore steps)

# Install torch with CUDA support
RUN R -e "install.packages('torch', repos='https://cloud.r-project.org')"
RUN R -e "torch::install_torch(type='cuda', version='2.1.0')"

# Verify GPU access
RUN R -e "stopifnot(torch::cuda_is_available())"

WORKDIR /home/jovyan

LABEL org.opencontainers.image.version="v1.0-gpu" \
      handbook.requires-gpu="true"
```

**Build and Push** (CI workflow):
```bash
docker build -f .docker/base.Dockerfile -t ghcr.io/fao-eostat/handbook-base:v1.0 .
docker build -f .docker/gpu.Dockerfile -t ghcr.io/fao-eostat/handbook-base-gpu:v1.0 .
docker push ghcr.io/fao-eostat/handbook-base:v1.0
docker push ghcr.io/fao-eostat/handbook-base-gpu:v1.0
```

### 3.3 Onyxia Helm Chart

**Chart Structure**:
```
handbook-catalog/
├── chapter-session/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── serviceaccount.yaml  # ← NEW: For IRSA
│       ├── deployment.yaml
│       ├── service.yaml
│       └── ingress.yaml
```

**Chart.yaml**:
```yaml
apiVersion: v2
name: chapter-session
version: 1.0.0
description: UN Handbook reproducible analysis session
type: application
keywords:
  - jupyter
  - r
  - reproducibility
  - geospatial
home: https://fao-eostat.github.io/UN-Handbook/
sources:
  - https://github.com/FAO-EOSTAT/UN-Handbook
maintainers:
  - name: UN Handbook Team
    email: un-handbook@example.org
icon: https://jupyter.org/assets/homepage/main-logo.svg
```

**values.yaml**:
```yaml
# Chapter information (passed via Onyxia deep-link)
chapter:
  name: "ct_chile"
  dataSnapshot: "sha256-abcdef123"  # Content hash from CI

# Image selection (base or GPU)
image:
  repository: "ghcr.io/fao-eostat/handbook-base"
  tag: "v1.0"
  pullPolicy: IfNotPresent

# Resource allocation (tier-based)
resources:
  requests:
    cpu: "2000m"
    memory: "8Gi"
  limits:
    cpu: "6000m"
    memory: "24Gi"

# GPU support
gpu:
  enabled: false
  count: 1

# ServiceAccount for IRSA (Workload Identity)
serviceAccount:
  create: true
  annotations: {}
  # Populated by Onyxia region.customValues:
  # annotations:
  #   eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/handbook-reader

# AWS configuration
aws:
  region: "us-west-2"
  # No credentials - IRSA provides them automatically

# Service configuration
service:
  type: ClusterIP
  port: 8888
  targetPort: 8888

# Ingress (Onyxia auto-configures subdomain)
ingress:
  enabled: true
  className: "{{onyxia.k8s.ingressClassName}}"
  hostname: "chapter-{{onyxia.k8s.randomSubdomain}}.{{onyxia.k8s.domain}}"
  tls: true

# Security (chart-specific implementation of region defaults)
security:
  ipProtection:
    enabled: "{{onyxia.region.defaultIpProtection}}"
    ip: "{{onyxia.user.ip}}"
  networkPolicy:
    enabled: "{{onyxia.region.defaultNetworkPolicy}}"

# Ephemeral session (no home persistence)
persistence:
  enabled: false

# Onyxia context (injected at deploy time)
onyxia:
  s3:
    AWS_BUCKET_NAME: ""
    AWS_S3_ENDPOINT: ""
    # Fallback credentials (only if IRSA not available)
    AWS_ACCESS_KEY_ID: ""
    AWS_SECRET_ACCESS_KEY: ""
    AWS_SESSION_TOKEN: ""
```

**templates/serviceaccount.yaml** (NEW):
```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "chapter-session.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "chapter-session.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
```

**templates/deployment.yaml**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "chapter-session.fullname" . }}
  namespace: {{ .Release.Namespace }}
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "chapter-session.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "chapter-session.selectorLabels" . | nindent 8 }}
        chapter: {{ .Values.chapter.name }}
    spec:
      serviceAccountName: {{ include "chapter-session.serviceAccountName" . }}
      securityContext:
        runAsUser: 1000
        runAsGroup: 100
        fsGroup: 100
      containers:
      - name: jupyterlab
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        command:
          - jupyter
          - lab
          - --ip=0.0.0.0
          - --port=8888
          - --no-browser
          - --NotebookApp.token=''
          - --NotebookApp.password=''
        ports:
        - name: http
          containerPort: 8888
          protocol: TCP
        env:
        - name: CHAPTER_NAME
          value: {{ .Values.chapter.name }}
        - name: CHAPTER_VERSION
          value: {{ .Values.chapter.version }}
        - name: ONYXIA_USER
          value: {{ .Values.onyxia.user.idep | quote }}
        # AWS region (always needed)
        - name: AWS_DEFAULT_REGION
          value: {{ .Values.aws.region | default "us-west-2" | quote }}
        # S3 endpoint and bucket info
        {{- if .Values.onyxia.s3 }}
        - name: AWS_S3_ENDPOINT
          value: {{ .Values.onyxia.s3.AWS_S3_ENDPOINT | default "https://s3.amazonaws.com" | quote }}
        - name: AWS_BUCKET_NAME
          value: {{ .Values.onyxia.s3.AWS_BUCKET_NAME | quote }}
        {{- end }}
        # FALLBACK: xOnyxiaContext credentials (only if IRSA not available)
        # AWS SDK automatically prefers IRSA when ServiceAccount has annotation
        {{- if and .Values.onyxia.s3 .Values.onyxia.s3.AWS_ACCESS_KEY_ID }}
        - name: AWS_ACCESS_KEY_ID
          value: {{ .Values.onyxia.s3.AWS_ACCESS_KEY_ID | quote }}
        - name: AWS_SECRET_ACCESS_KEY
          value: {{ .Values.onyxia.s3.AWS_SECRET_ACCESS_KEY | quote }}
        - name: AWS_SESSION_TOKEN
          value: {{ .Values.onyxia.s3.AWS_SESSION_TOKEN | quote }}
        {{- end }}
        resources:
          requests:
            cpu: {{ .Values.resources.requests.cpu }}
            memory: {{ .Values.resources.requests.memory }}
          limits:
            cpu: {{ .Values.resources.limits.cpu }}
            memory: {{ .Values.resources.limits.memory }}
            {{- if .Values.gpu.enabled }}
            nvidia.com/gpu: {{ .Values.gpu.count }}
            {{- end }}
        volumeMounts:
        - name: chapter-data
          mountPath: /home/jovyan/handbook-chapter
          readOnly: true
        - name: dshm
          mountPath: /dev/shm
        livenessProbe:
          httpGet:
            path: /api
            port: http
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /api
            port: http
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: chapter-data
        csi:
          driver: csi-image.k8s.io
          volumeAttributes:
            image: "ghcr.io/fao-eostat/handbook-data:{{ .Values.chapter.name }}-{{ .Values.chapter.dataSnapshot }}"
          readOnly: true
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: 2Gi
      {{- if .Values.gpu.enabled }}
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      {{- end }}
```

**templates/service.yaml**:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "chapter-session.fullname" . }}
  namespace: {{ .Release.Namespace }}
spec:
  type: {{ .Values.service.type }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: http
    protocol: TCP
    name: http
  selector:
    {{- include "chapter-session.selectorLabels" . | nindent 4 }}
```

**templates/ingress.yaml**:
```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "chapter-session.fullname" . }}
  namespace: {{ .Release.Namespace }}
  annotations:
    {{- if .Values.security.ipProtection.enabled }}
    nginx.ingress.kubernetes.io/whitelist-source-range: {{ .Values.security.ipProtection.ip }}
    {{- end }}
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: {{ .Values.ingress.className }}
  tls:
  - hosts:
    - {{ .Values.ingress.hostname }}
    secretName: {{ include "chapter-session.fullname" . }}-tls
  rules:
  - host: {{ .Values.ingress.hostname }}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: {{ include "chapter-session.fullname" . }}
            port:
              number: {{ .Values.service.port }}
{{- end }}
```

**Packaging for Onyxia Catalog**:
```bash
# Package the chart
helm package handbook-catalog/chapter-session/

# Generate index
helm repo index handbook-catalog/ --url https://fao-eostat.github.io/handbook-catalog

# Host on GitHub Pages
git add handbook-catalog/index.yaml handbook-catalog/chapter-session-1.0.0.tgz
git commit -m "Add handbook chapter session chart"
git push
```

### 3.4 CI/CD: Auto-generate Chapter Metadata

**GitHub Actions Workflow** (`.github/workflows/generate-metadata.yml`):

```yaml
name: Generate Chapter Metadata

on:
  push:
    branches:
      - main
    paths:
      - '*.qmd'
      - 'chapters/*.qmd'
  workflow_dispatch:

jobs:
  generate-metadata:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup R
        uses: r-lib/actions/setup-r@v2
        with:
          r-version: '4.5.1'

      - name: Install dependencies
        run: |
          Rscript -e "install.packages(c('yaml', 'jsonlite', 'purrr'))"

      - name: Scan all chapters
        run: |
          Rscript scripts/scan-all-chapters.R > chapters.json
          cat chapters.json

      - name: Update pre-warming job
        run: |
          # Extract chapters and generate YAML array for pre-warming job
          # This is an example - adapt to your needs
          cat chapters.json | jq -r 'to_entries[] | "\(.key):\(.value.version):\(.value.storage_size)"' > chapters.txt

      - name: Commit changes
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add chapters.json
          git diff --quiet && git diff --staged --quiet || \
            (git commit -m "chore: update chapter metadata" && git push)
```

**R Script** (`scripts/scan-all-chapters.R`):

```r
#!/usr/bin/env Rscript
library(yaml)
library(jsonlite)
library(purrr)

# Find all .qmd files
qmd_files <- list.files(
  path = ".",
  pattern = "\\.qmd$",
  recursive = TRUE,
  full.names = TRUE
)

# Function to extract reproducible metadata
extract_metadata <- function(file) {
  tryCatch({
    lines <- readLines(file, warn = FALSE)

    # Find YAML frontmatter
    yaml_start <- which(lines == "---")[1]
    yaml_end <- which(lines == "---")[2]

    if (is.na(yaml_start) || is.na(yaml_end)) {
      return(NULL)
    }

    yaml_text <- paste(lines[(yaml_start+1):(yaml_end-1)], collapse = "\n")
    metadata <- yaml.load(yaml_text)

    # Check if reproducible metadata exists
    if (is.null(metadata$reproducible) || !isTRUE(metadata$reproducible$enabled)) {
      return(NULL)
    }

    # Extract chapter name
    chapter_name <- tools::file_path_sans_ext(basename(file))

    # Build metadata object
    list(
      tier = metadata$reproducible$tier %||% "medium",
      image_flavor = metadata$reproducible$`image-flavor` %||% "base",
      version = metadata$reproducible$`data-snapshot` %||% "v1.0.0",
      oci_image = sprintf(
        "ghcr.io/fao-eostat/handbook-data:%s-%s",
        chapter_name,
        metadata$reproducible$`data-snapshot` %||% "v1.0.0"
      ),
      estimated_runtime = metadata$reproducible$`estimated-runtime` %||% "Unknown",
      storage_size = metadata$reproducible$`storage-size` %||% "20Gi"
    )
  }, error = function(e) {
    warning(sprintf("Error parsing %s: %s", file, e$message))
    return(NULL)
  })
}

# Scan all chapters
chapters <- qmd_files %>%
  set_names(tools::file_path_sans_ext(basename(.))) %>%
  map(extract_metadata) %>%
  compact()  # Remove NULLs

# Output as JSON
cat(toJSON(chapters, pretty = TRUE, auto_unbox = TRUE))
```

---

## Implementation Roadmap

### Phase 1: Foundation
-  Build base/GPU Docker images with curated system dependencies
-  Configure EKS cluster for OIDC provider (IRSA)
-  Create IAM role with S3 read permissions
-  **Spike**: Validate CSI Image Driver installation and functionality

### Phase 2: CI-Driven Data Packaging
- Build automated GitHub Actions workflow for data packaging
- Implement content-hash calculation (SHA256)
- Configure auto-commit of hashes back to `.qmd` files
- Test OCI artifact builds and pushes to GHCR
- Validate immutable, content-addressed artifacts

### Phase 3: Helm Chart & Integration
- Develop Onyxia Helm chart with ServiceAccount for IRSA
- Implement CSI image volume mounting
- Configure `region.customValues` in Onyxia for IRSA role ARN
- Build Quarto extension for "Reproduce" button generation
- Test hybrid credential approach (IRSA primary, xOnyxiaContext fallback)

### Phase 4: Long-Term Dependency Management
- Extend CI pipeline to detect `renv.lock` changes
- Build chapter-specific compute images automatically
- Implement versioning strategy for compute images
- Handle dependency conflicts across chapters

### Phase 5: Production Launch
- Rollout to production environment
- Conduct load testing (concurrent users)
- Establish monitoring and alerting
- Document author workflow
- Train chapter authors


### Performance Comparison

| Metric | Old Approach (PVC Cloning) | New Approach (CSI Image Driver) | Improvement |
|--------|----------------------------|----------------------------------|-------------|
| First user startup | 60s (create golden PVC) | 15-30s (node pulls image) | **2-4× faster** |
| Second user startup | 5-15s (clone PVC) | **5-15s** (node cache hit) | **Same performance** |
| State management | Golden PVCs + cleanup jobs | **Stateless** (K8s image cache) | **Zero management** |
| Storage overhead | 1 golden PVC per chapter | **None** (standard image cache) | **Infrastructure simplified** |
| Reproducibility | Version tags | **Content hashes** (SHA256) | **Immutable artifacts** |
| Author workflow | Manual script execution | **Fully automated CI** | **Zero friction** |


**Template Syntax Notes**:
- Omit `{{}}` in `values.schema.json` `overwriteDefaultWith` field: `"user.email"`
- Include `{{}}` in `values.yaml` default values: `"{{onyxia.user.email}}"`
- Concatenation: `"{{project.id}}-{{k8s.randomSubdomain}}.{{k8s.domain}}"`
- Arrays: `"overwriteDefaultWith": ["value1", "{{region.oauth2.clientId}}"]`
- Objects: `"overwriteDefaultWith": {"foo": "bar", "bar": "{{region.oauth2.clientId}}"}`
