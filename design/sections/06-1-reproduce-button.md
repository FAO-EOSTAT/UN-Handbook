##### Component #4: "Reproduce" Button (Quarto Extension)

**User's Entrypoint to Reproducible Sessions**

::: {.callout-note}
## Implementation Status
This component is **IMPLEMENTED** and available at [github.com/cslovell/reproducible](https://github.com/cslovell/reproducible). The documentation below describes the high-level architecture. For implementation details, code examples, and installation instructions, see the external repository.
:::

###### Overview

The "Reproduce" button is a Lua-based Quarto extension that reads chapter metadata and generates an Onyxia deep-link URL. It serves as the user's primary entrypoint for launching reproducible analysis sessions directly from handbook chapters.

###### Extension Structure

```
_extensions/reproducible-button/
├── _extension.yml
├── reproduce-button.lua (deep-link generator)
└── reproduce-button.js (optional UI enhancements)
```

###### Author Usage

**Minimal Usage (Recommended)**:

```yaml
---
title: "Crop Type Mapping - Chile"
reproducible:
  enabled: true
  # Smart defaults applied:
  # - tier: auto-detected (medium for RF, heavy for large datasets, gpu for torch/luz)
  # - image-flavor: auto-detected (gpu if torch/luz found, otherwise base)
  # - data-snapshot: auto-updated by CI
  # - estimated-runtime: auto-estimated from data size
  # - storage-size: auto-calculated from data/ directory
---

{{< reproduce-button >}}

# Chapter content...
```

**Advanced Usage (Optional Overrides)**:

```yaml
---
title: "Crop Type Mapping - Chile"
reproducible:
  enabled: true
  tier: heavy              # Override auto-detection
  image-flavor: gpu        # Override auto-detection
  estimated-runtime: "45 minutes"
  storage-size: "50Gi"
---

{{< reproduce-button >}}

# Chapter content...
```

###### Rendered Output

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

###### Implementation

**Note**: The full implementation is available at [github.com/cslovell/reproducible](https://github.com/cslovell/reproducible). The code below is provided for reference to illustrate the architecture.

**Conceptual Reference** (see external repo for actual implementation):

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
  )
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

  -- Extract semantic values (no hard-coded infrastructure details)
  local tier = meta.reproducible.tier or "medium"
  local image_flavor = meta.reproducible["image-flavor"] or "base"
  local data_snapshot = meta.reproducible["data-snapshot"] or "v1.0.0"
  local storage_size = meta.reproducible["storage-size"] or "20Gi"
  local estimated_runtime = meta.reproducible["estimated-runtime"] or "Unknown"

  -- Normalize version (dots to hyphens)
  local version_normalized = data_snapshot:gsub("%.", "-")

  -- Build Onyxia deep-link URL
  local base_url = "https://datalab.officialstatistics.org/launcher/handbook/chapter-session"

  local params = {
    "autoLaunch=true",
    "name=" .. encode_helm_value("chapter-" .. chapter_name),

    -- Pass semantic tier and flavor (Helm chart will interpret)
    "tier=" .. encode_helm_value(tier),
    "imageFlavor=" .. encode_helm_value(image_flavor),

    -- Chapter parameters
    "chapter.name=" .. encode_helm_value(chapter_name),
    "chapter.version=" .. encode_helm_value(version_normalized),
    "chapter.storageSize=" .. encode_helm_value(storage_size)
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

###### Key Design Decisions

**Semantic Configuration**: The extension only passes semantic names (`tier: "heavy"`, `imageFlavor: "gpu"`) to the Helm chart. The actual resource allocations and image repositories are defined server-side in the Helm chart templates (see ["Chapter Session" Helm Chart](#component-5-chapter-session-helm-chart)).

**No Hard-Coded Infrastructure**: The Lua script contains no CPU values, memory amounts, or image tags. This ensures infrastructure changes don't require re-rendering the static handbook site.

**Auto-Launch**: The deep-link includes `autoLaunch=true`, which instructs Onyxia to immediately deploy the session without requiring additional user interaction.

**Chapter Identification**: The extension automatically extracts the chapter name from the `.qmd` filename and normalizes the version string for URL compatibility.
