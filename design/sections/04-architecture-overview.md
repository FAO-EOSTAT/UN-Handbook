#### Architecture Overview

This reproducible analysis system consists of **five custom software components** that integrate with existing platforms (Kubernetes, Onyxia, AWS, and container registries) to enable one-click reproducible chapter sessions. The architecture operates in two distinct phases: a **Build-Time Flow** (automated CI/CD for chapter authors) and a **Run-Time Flow** (one-click session launching for readers).

::: {.callout-important}
## Implementation Status Summary
**Frontend (Component #4)**: IMPLEMENTED at [github.com/cslovell/reproducible](https://github.com/cslovell/reproducible)
**Backend (Components #1, #2, #3, #5)**: NOT IMPLEMENTED (estimated Q1 2026)

The Quarto extension is functional and generates correct URLs, but clicking the button will result in an error until backend infrastructure is deployed.
:::

##### Build-Time Flow: Automated CI/CD Pipeline

When a chapter author pushes changes to the repository, an automated CI/CD pipeline ensures that all data and compute dependencies are versioned, built, and deployed as immutable OCI artifacts.

```
                    [Chapter Author]
                          |
                          v
                    [git push]
                     /        \
                    /          \
         (data/ct_chile/)   (renv.lock / Dockerfile)
                  |                    |
                  v                    v
     [Portable CI Pipeline (Dagger)]  [Portable CI Pipeline (Dagger)]
          Data Packaging (#3)          Image Build (#2)
                  |                    |
                  v                    v
          [OCI Data Artifact]    [Curated Compute Image]
           (tag: sha256-abc...)   (tag: base:v1.1)
                  |                    |
                  +------[GHCR]--------+
                  |
                  v
          [Auto-commit hash back]
          (via Dagger pipeline)
                  |
                  v
           (ct_chile.qmd:
            data-snapshot: sha256-abc...)
```

**Key Components in Build-Time Flow**:

1. **Portable CI Pipeline - Data Packaging (#3)**: A Dagger SDK function that automatically detects changes to chapter `data/` directories, builds content-hashed OCI data artifacts, pushes them to the container registry (GHCR), and auto-commits the new hash back to the `.qmd` file's YAML frontmatter. Triggered by simple one-line wrappers in GitHub Actions, GitLab CI, or run locally. (See [Portable CI/CD Pipeline](#component-1-portable-cicd-pipeline-dagger-sdk) for implementation)

2. **Portable CI Pipeline - Image Build (#2)**: A Dagger SDK function that builds pre-built, immutable container images containing specific R/Python versions, all `renv`/`pip` packages, and system libraries (GDAL, PROJ). These images are rebuilt via Dagger when `renv.lock` or Dockerfiles change. (See [Curated Compute Images](#component-2-curated-compute-images) for image variants)

3. **Portable CI Pipeline - Metadata Generation (#5)**: A Dagger SDK function that scans all `.qmd` files and aggregates their `reproducible:` metadata into a centralized `chapters.json` manifest, which can be used for cluster optimizations like image pre-warming. (See [Portable CI/CD Pipeline](#component-1-portable-cicd-pipeline-dagger-sdk) for implementation)

##### Run-Time Flow: One-Click Reproducible Sessions

When a handbook reader clicks the "Reproduce this analysis" button, the system orchestrates a fully configured Kubernetes session with all code, data, and cloud credentials ready.

```
           [Handbook Reader]
                  |
                  v
       [Clicks "Reproduce" button]
                  |
                  v
       [Quarto Extension reads YAML]
               (#1)
                  |
                  v
       [Generates Onyxia deep link]
          (pre-filled with params)
                  |
                  v
       +---------[Onyxia]----------+
       |   (Existing Platform)     |
       |  - User Authentication    |
       |  - UI for Launch Params   |
       +---------------------------+
                  |
            [User clicks "Launch"]
                  |
                  v
       [Onyxia calls Helm Chart]
               (#4)
                  |
                  v
       +--------[Kubernetes API]--------+
       |    (Existing Platform)         |
       +---------------------------------+
              /              \
             /                \
            v                  v
    [Pull Compute Image]  [CSI Image Driver]
         (#2)              (Existing Cluster Component)
    (base:v1.1)                  |
                                 v
                         [Mount Data Artifact]
                            (sha256-abc...)
                         as read-only volume
            |                    |
            +--------------------+
                     |
                     v
              [Pod Running]
         +--------------------+
         | - JupyterLab       |
         | - All code         |
         | - Local data       |
         | - AWS credentials  |
         |   (via IRSA)       |
         +--------------------+
```

**Key Components in Run-Time Flow**:

1. **"Reproduce" Button Quarto Extension (#1)**: A Lua-based Quarto extension that reads `reproducible:` metadata from chapter YAML frontmatter and dynamically generates an Onyxia deep link URL, pre-filling all launch parameters (resource tier, image tag, data snapshot hash). (See ["Reproduce" Button](#component-4-reproduce-button-quarto-extension))

4. **"Chapter Session" Helm Chart (#4)**: An Onyxia-compatible Helm chart that defines the reproducible session in Kubernetes. It creates a `ServiceAccount` with IRSA annotations (for AWS cloud access), defines the `Deployment` (specifying which Compute Image to run), and configures a volume mount using the CSI Image Driver to attach the OCI data artifact as a read-only filesystem. (See ["Chapter Session" Helm Chart](#component-5-chapter-session-helm-chart) for chart structure)

**Existing Platform Components**: The system relies on standard Kubernetes features (CSI Image Driver for volume mounting, IRSA for AWS credential injection) and Onyxia for user authentication and service orchestration.

##### The Five Core Components

This system is built from five custom software components that work together to enable reproducible analysis:

**Build-Time Components** (automated CI/CD):

- **Component #1: Portable CI Pipeline (Dagger)** - **[NOT IMPLEMENTED]** - Orchestrates all build-time tasks: building compute images, packaging data artifacts, and generating metadata. Runs identically on developer laptops, GitHub Actions, or GitLab CI. (See [Portable CI/CD Pipeline](#component-1-portable-cicd-pipeline-dagger-sdk))

- **Component #2: Curated Compute Images** - **[NOT IMPLEMENTED]** - Pre-built Docker images containing R/Python environments, system libraries (GDAL, PROJ, GEOS), and all package dependencies from `renv.lock`. Available in `base` and `gpu` flavors (GPU support subject to funding). (See [Curated Compute Images](#component-2-curated-compute-images))

- **Component #3: OCI Data Artifacts** - **[NOT IMPLEMENTED]** - Content-hashed, immutable data snapshots packaged as OCI images. Mounted directly as read-only volumes using the CSI Image Driver, enabling fast startup (5-15s) via node-level caching. (See [OCI Data Artifacts](#component-3-oci-data-artifacts))

**Run-Time Components** (user-facing):

- **Component #4: "Reproduce" Button (Quarto Extension)** - **[IMPLEMENTED at [github.com/cslovell/reproducible](https://github.com/cslovell/reproducible)]** - A Lua-based Quarto extension that reads chapter metadata and generates an Onyxia deep-link URL. The user's entrypoint to launching a reproducible session. (See ["Reproduce" Button](#component-4-reproduce-button-quarto-extension))

- **Component #5: "Chapter Session" (Helm Chart)** - **[NOT IMPLEMENTED]** - An Onyxia-compatible Helm chart that deploys the Kubernetes session. Translates semantic tier names (`heavy`, `gpu`) into actual resource allocations, mounts data artifacts, and configures cloud credentials via IRSA. (See ["Chapter Session" Helm Chart](#component-5-chapter-session-helm-chart))

**Cross-Cutting Capabilities**:

- **Onyxia Deep Link Integration** - Bridges the button click to session deployment via pre-filled URL parameters. (See [Onyxia Deep-Link Mechanism](#onyxia-deep-link-mechanism))

- **Cloud Data Access (IRSA)** - Provides automatic AWS credentials for accessing S3-hosted satellite imagery via Kubernetes Workload Identity. (See [Cloud Data Access](#using-cloud-credentials-in-analysis-code))

##### Decoupled Configuration Architecture

This system uses a **decoupled configuration architecture** where the Quarto site (frontend) is unaware of infrastructure details.

**Frontend (Quarto Site)**:
- **Knows**: Semantic names (`tier: "heavy"`, `imageFlavor: "gpu"`)
- **Doesn't know**: CPU counts, memory sizes, image repositories, version tags
- **Generates**: Deep-link URLs with semantic parameters

**Backend (Helm Chart)**:
- **Knows**: Resource tier mappings, image repositories, version tags
- **Translates**: Semantic names → Kubernetes resource specifications
- **Maintains**: Single Source of Truth for infrastructure config in `templates/deployment.yaml`

**Benefits**:

1. **Decoupling**: Infrastructure changes don't require re-rendering the Quarto book
2. **SSOT**: Resource tiers and image mappings defined once in Helm chart templates
3. **Versioning**: Helm chart version controls infrastructure config changes
4. **Testing**: Infrastructure team can update staging Helm chart independently
5. **Maintainability**: Change tier from 10 CPU → 12 CPU in one place (Helm chart)
6. **No Drift**: Frontend can never reference outdated resource values

**Example Workflow**:

When infrastructure needs to change the `heavy` tier from 10 CPU to 12 CPU:

1. Infrastructure team updates `templates/deployment.yaml`:
   ```yaml
   "heavy" (dict "cpu" "12000m" "memory" "48Gi" "storage" "50Gi")
   ```
2. Deploy new Helm chart version (`v1.1.0`)
3. No changes needed to Quarto site
4. Next user clicks "Reproduce" button → gets 12 CPU automatically

