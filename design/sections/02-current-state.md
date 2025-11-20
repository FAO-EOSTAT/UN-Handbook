#### Current State & Design Goals

##### Current State

The UN Handbook is a Quarto book with 48 chapters. **Only 2 chapters (4%) currently have local data dependencies** that would benefit from reproducible containers (ct_chile, ct_digital_earth_africa). Most chapters (84%) are cloud-only or theoretical, accessing satellite imagery directly via STAC catalogs. The few chapters with local data use it for pre-computed models, training samples, and cached results to avoid expensive recomputation. Chapters use R (with renv), some Python, and access both local cached data (RDS files, models) and remote cloud data (STAC catalogs).

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

##### Computational Characteristics

###### Analysis Types by Computational Load

**Light (Theory Chapters)**:

- Educational examples with small datasets
- Code snippets with `eval: false`
- **Resource allocation**: 2 CPU, 8GB RAM, 10GB storage (defined in Helm chart)
- **Typical runtime**: Minutes

**Medium (Crop Statistics)**:

- Google Earth Engine data access
- Sample-based area estimators
- Statistical methods
- **Resource allocation**: 6 CPU, 24GB RAM, 20GB storage (defined in Helm chart)
- **Typical runtime**: 15-30 minutes

**Heavy (Crop Type Mapping)**:

- Example: Chile chapter
  - Sentinel-2 imagery via STAC
  - 62,920 training points from 4,140 polygons
  - Random Forest classification
  - Self-Organizing Maps
  - 22 RDS files (models, samples, classifications)
- **Resource allocation**: 10 CPU, 48GB RAM, 50GB storage (defined in Helm chart)
- **Typical runtime**: 1-2 hours

::: {.callout-important}
###### GPU Support Availability
GPU-enabled sessions are subject to funding availability and cluster configuration. While the infrastructure design includes GPU support for deep learning workloads, actual GPU resource allocation on the UN Global Platform depends on budget and infrastructure capacity. GPU support is not part of the initial deployment.
:::

**GPU (Deep Learning)**:

- Example: Colombia chapter (crop yield estimation)
  - Sentinel-1 SAR data processing
  - Deep learning with `luz` (PyTorch for R)
  - Requires GPU for reasonable performance
  - 23 cache entries
- **Resource allocation**: 8 CPU, 32GB RAM, 1 GPU, 50GB storage (defined in Helm chart)
- **Typical runtime**: 2-4 hours

##### Current Technology Stack

###### R Environment
- **R Version**: 4.5.1
- **Package Manager**: `renv` with lock file (7,383 lines, ~427KB)
- **Key Packages**:
  - Geospatial: `sits`, `sf`, `terra`, `stars`, `lwgeom`
  - Cloud Access: `rstac`, `earthdatalogin`, `arrow`, `gdalcubes`
  - Machine Learning: `randomForest`, `ranger`, `e1071`, `kohonen`
  - Deep Learning: `torch`, `luz`
  - Visualization: `ggplot2`, `tmap`, `leaflet`
  - Python Integration: `reticulate` (for Indonesia chapter)

###### Python Environment
- **Status**: One chapter (Indonesia) uses Python via `reticulate`
- **Solution**: Create `requirements.txt` for reproducibility

###### Data Sources

**Cloud Platforms (Remote Access)**:

- Microsoft Planetary Computer (MPC)
- AWS (Sentinel-2 L2A)
- Digital Earth Africa
- Brazil Data Cube (BDC)
- Copernicus Data Space Ecosystem (CDSE)
- NASA HLS (Harmonized Landsat-Sentinel)
- Google Earth Engine

**Local Storage**:

- `/data` directory: 59 MB across 2 chapter-specific subdirectories
  - `data/ct_chile/` (57 MB): Chile crop classification models, samples, ROI boundaries
  - `data/ct_digital_earth_africa/` (2 MB): Rwanda training data and validation results
- `/etc` directory: 227 MB of **shared teaching artifacts**
  - Purpose: Pre-computed models and cached results for theory chapters
  - Usage: Allows readers to explore concepts without expensive recomputation
  - **Note**: This is legitimate shared infrastructure, not misplaced chapter data
- **Data Types**: RDS files (models, cubes, samples), Shapefiles, Geoparquet, TIFF (gitignored)

**Data Organization Patterns**:

- **Chapter-specific data**: Stored in `data/<chapter>/` (e.g., `data/ct_chile/`) → Packaged in reproducible containers
- **Shared teaching artifacts**: Theory chapters use `etc/` directory for pre-computed demonstrations
- **Cloud-only chapters**: Most chapters (84%) access satellite imagery directly via STAC catalogs with no local data

**Access Pattern**:

- Preferred: Cloud-native via STAC protocol (most chapters follow this pattern)
- Hybrid: Some chapters combine local cached results with live cloud data access
- Reality: Only 2 chapters currently use local data for reproducible containers

##### Current Reproducibility Status

**Strengths**:

-  `renv` lock file with complete R package snapshot
-  Version control with clear structure
-  Modular design (each chapter independent)
-  Cloud-native workflows using STAC (84% of chapters)
-  Chapter-specific data directories already established (`data/<chapter>/` pattern)
-  Excellent data hygiene in chapters with local data

**Gaps for Reproducible Containers** (applies to ~4% of chapters with local data):

-  No containerization (no Dockerfile)
-  No CI/CD or automated testing
-  No YAML frontmatter for reproducible configuration
-  Python dependencies unmanaged (one chapter uses reticulate)
-  System dependencies (GDAL, PROJ, GEOS) versions unspecified
-  Computational requirements undocumented

**Note**: Pre-computed results (RDS files) are intentional for performance, not a gap. They enable demonstration of expensive analyses (e.g., 2-hour deep learning training) without requiring readers to re-run full computations.

---

##### Design Requirements & Principles

###### Key Decisions

1. **Resource Allocation**: Dynamic (auto-scale per chapter based on metadata)
2. **Data Strategy**: Pre-packaged, content-hashed, and immutable OCI artifacts for local data; automatic OIDC-based credentials for live cloud data.
3. **User Interface**: JupyterLab (supports R/Python)
4. **Session Duration**: Ephemeral (e.g., 2-hour auto-cleanup)
5. **Platform Integration**: Orchestrated by Onyxia, but with a portable core
6. **Cloud Access**: Automatic, temporary AWS credentials via standard Kubernetes Workload Identity (IRSA)

###### Design Principles

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

##### Chapter Classification and Implementation Priorities

Based on analysis of all 48 handbook chapters, they are organized into five categories with different reproducibility requirements and implementation priorities:

###### Category A: Theory and Conceptual Chapters (14 chapters)
**Chapters**: 4, 7, 12, 13, 15, 17, 21, 24, 25, 26, 27, 28, 31, 36

These chapters contain no executable code or provide conceptual frameworks.

**Reproducibility Status**: Not applicable
**Button Enabled**: No
**Implementation Priority**: N/A

###### Category B: Cloud-Only Reproducible Code (6 chapters)
**Chapters**: 5, 6, 8, 9, 10, 11

These chapters provide executable code that accesses satellite imagery directly via STAC catalogs (Microsoft Planetary Computer, AWS Sentinel-2, Digital Earth Africa, etc.). No local data files required.

**Reproducibility Status**: Ready for button (backend deployment pending)
**Button Enabled**: Can be enabled for preparation
**Resource Allocation**: Light tier (2 CPU, 8GB RAM) or Medium tier (6 CPU, 24GB RAM) based on computational requirements
**Data Strategy**: Cloud-only (no local data packaging needed)
**Implementation Priority**: Phase 2 (after infrastructure deployment)

###### Category C: Hybrid Reproducible Code (6 chapters)
**Chapters**: 19 (Chile), 20 (Digital Earth Africa), 23 (Colombia), 32 (China Crop Growth), 33 (Cook Islands), 35 (World Cereal)

These chapters combine local cached data (pre-trained models, training samples, intermediate results) with live cloud data access.

**Status**:
- Completed: Chile (19), Digital Earth Africa (20)
- In progress: Colombia (23), China Crop Growth (32), Cook Islands (33), World Cereal (35)

**Reproducibility Status**: Button enabled for Chile (19), ready for others
**Button Enabled**: Yes (Chile), can be enabled for others
**Resource Allocation**:
- Medium tier (6 CPU, 24GB RAM): Standard Random Forest classification
- Heavy tier (10 CPU, 48GB RAM): Large-scale classification, SAR preprocessing
- GPU tier (8 CPU, 32GB RAM, 1 GPU): Deep learning (Colombia yield estimation)

**Data Strategy**: Hybrid (local data artifacts + cloud STAC access)
**Local Data**: Stored in `data/<chapter>/` directory
**Implementation Priority**: Phase 1 (highest priority - already 2 chapters ready with data)

**Data Files**:
- Chile (19): 57 MB (models, samples, ROI boundaries)
- Digital Earth Africa (20): 2 MB (training data, validation results)
- Others: TBD during upcoming work

###### Category D: External GitHub Resources (5 chapters)
**Chapters**: 14, 16, 18, 29, 34

These chapters reference GitHub repositories or code that would be too cumbersome to package in the UN Environment. They are provided as external links.

**Reproducibility Status**: Provided as external links
**Button Enabled**: No
**Implementation Priority**: N/A (external resource management strategy)

###### Category E: Incomplete Chapters (2 chapters)
**Chapters**: 22, 30

These chapters have incomplete code or missing data components and are not yet ready for reproducibility.

**Reproducibility Status**: Not ready
**Button Enabled**: No
**Implementation Priority**: Low (complete chapter development first)

###### Implementation Roadmap

**Phase 1: Infrastructure Foundation (Weeks 1-4)**
- Deploy CSI Image Driver
- Configure IRSA for AWS access
- Build base compute image (R 4.5.1, GDAL, geospatial packages)
- Deploy Helm chart
- **Enables**: Basic button functionality

**Phase 2: Category C Chapters (Weeks 5-8)**
- Implement Dagger CI pipeline
- Package data for Chile (19) and DEA (20)
- Complete Colombia (23), China (32), Cook Islands (33), World Cereal (35)
- Deploy to production
- **Enables**: 6 chapters with local data

**Phase 3: Category B Chapters (Weeks 9-10)**
- Enable button for cloud-only chapters (5, 6, 8, 9, 10, 11)
- Test STAC access with IRSA credentials
- Document workflow
- **Enables**: 6 additional chapters

**Phase 4: Documentation & Training (Weeks 11-12)**
- Update handbook documentation
- Author training sessions
- Create video tutorials
- Establish support channels
- **Enables**: Full rollout

###### Decision Tree for Chapter Authors

To determine if a chapter should enable the reproducible button:

1. **Does your chapter contain executable code?**
   - No → Category A (No button)
   - Yes → Continue to step 2

2. **Does it require local data files?**
   - No → Category B (Button, cloud-only, light/medium tier)
   - Yes → Continue to step 3

3. **Is the code/data complete?**
   - No → Category E (Complete first, then enable button)
   - Yes → Continue to step 4

4. **Is it better as external GitHub resource?**
   - Yes → Category D (External link, no button)
   - No → Category C (Button, hybrid data, medium/heavy/gpu tier)

