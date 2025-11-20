#### Implementation Roadmap

::: {.callout-note}
## Current Status
**Completed**: Quarto extension (Phase 3) - available at [github.com/cslovell/reproducible](https://github.com/cslovell/reproducible)
**In Progress**: None (backend implementation planned for Q1 2026)
:::

###### Phase 1: Foundation
-  Build base Docker images with curated system dependencies (GPU images contingent on funding)
-  Configure EKS cluster for OIDC provider (IRSA)
-  Create IAM role with S3 read permissions
-  **Spike**: Validate CSI Image Driver installation and functionality

###### Phase 2: Portable CI/CD with Dagger
- Implement Dagger SDK pipeline in Python (`ci/pipeline.py`)
- Build `package_data_artifacts()` function with content-hash calculation (SHA256)
- Build `build_compute_image()` function for Docker image builds
- Build `generate_metadata()` function for chapter metadata scanning
- Create thin GitHub Actions wrappers (`.github/workflows/*.yml`)
- Configure auto-commit of hashes back to `.qmd` files within Dagger pipeline
- Test OCI artifact builds and pushes to GHCR via Dagger
- Validate pipeline portability (local execution, GitHub Actions, GitLab CI)
- Validate immutable, content-addressed artifacts
- Document pipeline development and local testing workflow

###### Phase 3: Helm Chart & Integration
- Develop Onyxia Helm chart with ServiceAccount for IRSA
- Implement CSI image volume mounting
- Configure `region.customValues` in Onyxia for IRSA role ARN
- ✅ **COMPLETED**: Build Quarto extension for "Reproduce" button generation ([github.com/cslovell/reproducible](https://github.com/cslovell/reproducible))
- Test hybrid credential approach (IRSA primary, xOnyxiaContext fallback)

###### Phase 4: Long-Term Dependency Management
- Extend CI pipeline to detect `renv.lock` changes
- Build chapter-specific compute images automatically
- Implement versioning strategy for compute images
- Handle dependency conflicts across chapters

###### Phase 5: Production Launch
- Rollout to production environment
- Conduct load testing (concurrent users)
- Establish monitoring and alerting
- Document author workflow
- Train chapter authors
