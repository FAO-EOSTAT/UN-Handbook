-- Reproducible Analysis Button - Quarto Extension
-- Generates Onyxia deep-link buttons for launching reproducible sessions

-- ============================================
-- CONFIGURATION & HELPER FUNCTIONS
-- ============================================

-- Get configuration with fallback chain: document > project > extension defaults
local function get_config(meta)
  local config = meta["reproducible-config"] or {}

  return {
    onyxia = config.onyxia or {},
    ui = config.ui or {},
    branding = config.branding or {},
    tier_labels = config["tier-labels"] or {},
    defaults = config.defaults or {}
  }
end

-- Encode values for Onyxia URL parameters
-- Numbers/booleans pass as-is, strings are URL-encoded and wrapped in «»
local function encode_helm_value(value)
  if value == nil then
    return "null"
  end

  if type(value) == "boolean" then
    return tostring(value)
  end

  if type(value) == "number" then
    return tostring(value)
  end

  local str = tostring(value)

  -- Check if pure number (as string)
  if str:match("^%-?%d+%.?%d*$") then
    return str
  end

  -- URL encode (excluding safe chars: alphanumeric, - . _ ~)
  local encoded = str:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)

  -- Wrap in Onyxia delimiters
  return "«" .. encoded .. "»"
end

-- Safe metadata extraction with default
local function get_meta_string(meta, key, default)
  if meta and meta[key] then
    return pandoc.utils.stringify(meta[key])
  end
  return default
end

-- Get value with precedence: document > config.defaults > fallback
local function get_value(doc_meta, config, key, fallback)
  local value = get_meta_string(doc_meta, key)
  if value then return value end

  value = get_meta_string(config.defaults, key)
  if value then return value end

  return fallback
end

-- Extract chapter name from filename
local function extract_chapter_name(meta)
  -- Option 1: Explicit override
  if meta.reproducible and meta.reproducible["chapter-name"] then
    return pandoc.utils.stringify(meta.reproducible["chapter-name"])
  end

  -- Option 2: Extract from filename
  local input_file = quarto.doc.input_file
  if input_file then
    local name = input_file:match("([^/]+)%.qmd$")
    if name then
      return name
    end
  end

  -- Option 3: Fallback to sanitized title
  if meta.title then
    local title = pandoc.utils.stringify(meta.title)
    return title:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  end

  return "unknown-chapter"
end

-- Normalize version string (dots to hyphens)
local function normalize_version(version_str)
  if not version_str then
    return "latest"
  end
  return version_str:gsub("%.", "-")
end

-- Build Onyxia deep-link URL
local function build_onyxia_url(meta, config, validated_tier)
  -- Get Onyxia deployment settings from config
  local base_url = get_meta_string(config.onyxia, "base-url", "https://datalab.officialstatistics.org")
  local catalog = get_meta_string(config.onyxia, "catalog", "handbook")
  local chart = get_meta_string(config.onyxia, "chart", "chapter-session")
  local auto_launch = config.onyxia["auto-launch"]
  if auto_launch == nil then auto_launch = true end

  -- Build launcher URL
  local launcher_url = base_url .. "/launcher/" .. catalog .. "/" .. chart

  -- Extract chapter metadata with precedence
  local chapter_name = extract_chapter_name(meta)
  local image_flavor = get_value(meta.reproducible, config, "image-flavor", "base")
  local data_snapshot = get_value(meta.reproducible, config, "data-snapshot", "latest")
  local storage_size = get_value(meta.reproducible, config, "storage-size", "20Gi")

  -- Normalize version
  local version_normalized = normalize_version(data_snapshot)

  -- Build parameters (use validated_tier passed from Meta())
  local params = {
    "autoLaunch=" .. tostring(auto_launch),
    "name=" .. encode_helm_value("chapter-" .. chapter_name),
    "tier=" .. encode_helm_value(validated_tier),
    "imageFlavor=" .. encode_helm_value(image_flavor),
    "chapter.name=" .. encode_helm_value(chapter_name),
    "chapter.version=" .. encode_helm_value(version_normalized),
    "chapter.storageSize=" .. encode_helm_value(storage_size)
  }

  return launcher_url .. "?" .. table.concat(params, "&")
end

-- Generate HTML button markup based on notice style
local function generate_button_html(url, meta, config, validated_tier)
  -- Get UI configuration
  local button_text = get_meta_string(meta.reproducible, "button-text")
                   or get_meta_string(config.ui, "button-text", "Launch Environment")
  local notice_title = get_meta_string(config.ui, "notice-title", "Reproducible Environment Available")
  local notice_style = get_meta_string(meta.reproducible, "notice-style")
                    or get_meta_string(config.ui, "notice-style", "full")
  local session_duration = get_meta_string(config.ui, "session-duration", "2h")
  local show_runtime = config.ui["show-runtime"]
  if show_runtime == nil then show_runtime = true end

  -- Get branding
  local primary_color = get_meta_string(config.branding, "primary-color", "rgb(255, 86, 44)")
  local text_color = get_meta_string(config.branding, "text-color", "rgb(44, 50, 63)")
  local bg_color = get_meta_string(config.branding, "background-color", "#fafafa")

  -- Get other metadata (use validated_tier passed from Meta())
  local estimated_runtime = get_value(meta.reproducible, config, "estimated-runtime", "Unknown")

  -- Get tier label (with built-in fallbacks)
  local default_tier_labels = {
    light = "Light (2 CPU, 8GB RAM)",
    medium = "Medium (6 CPU, 24GB RAM)",
    heavy = "Heavy (10 CPU, 48GB RAM)",
    gpu = "GPU (8 CPU, 32GB RAM, 1 GPU)"
  }

  local tier_label = get_meta_string(config.tier_labels, validated_tier)
                  or default_tier_labels[validated_tier]
                  or validated_tier

  -- Build metadata text
  local metadata_parts = {tier_label}
  if show_runtime then
    table.insert(metadata_parts, "Est. runtime: " .. estimated_runtime)
  end
  table.insert(metadata_parts, "Auto-expires: " .. session_duration)
  local metadata_text = table.concat(metadata_parts, " • ")

  -- Generate HTML based on notice style
  if notice_style == "button-only" then
    -- Just the button, no wrapper
    return string.format([[
<a href="%s"
   target="_blank"
   class="reproducible-button"
   style="background: %s; color: white; padding: 6px 14px; text-decoration: none; border-radius: 3px; font-size: 0.9rem; font-weight: 500; display: inline-block; margin: 20px 0;">
  %s
</a>
]], url, primary_color, button_text)

  elseif notice_style == "minimal" then
    -- Button + metadata, no title
    return string.format([[
<div class="reproducible-notice minimal" style="border-left: 3px solid %s; background: %s; padding: 12px 16px; margin: 20px 0 30px 0; font-size: 0.95rem; color: %s;">
  <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap;">
    <a href="%s"
       target="_blank"
       style="background: %s; color: white; padding: 6px 14px; text-decoration: none; border-radius: 3px; font-size: 0.9rem; font-weight: 500; display: inline-block;">
      %s
    </a>
    <span style="color: #666; font-size: 0.85rem;">
      %s
    </span>
  </div>
</div>
]], primary_color, bg_color, text_color, url, primary_color, button_text, metadata_text)

  else
    -- "full" style (default) - Title + button + metadata
    return string.format([[
<div class="reproducible-notice full" style="border-left: 3px solid %s; background: %s; padding: 12px 16px; margin: 20px 0 30px 0; font-size: 0.95rem; color: %s;">
  <div style="margin-bottom: 6px;">
    <strong>%s</strong>
  </div>
  <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap;">
    <a href="%s"
       target="_blank"
       style="background: %s; color: white; padding: 6px 14px; text-decoration: none; border-radius: 3px; font-size: 0.9rem; font-weight: 500; display: inline-block;">
      %s
    </a>
    <span style="color: #666; font-size: 0.85rem;">
      %s
    </span>
  </div>
</div>
]], primary_color, bg_color, text_color, notice_title, url, primary_color, button_text, metadata_text)
  end
end

-- ============================================
-- MAIN FILTER FUNCTION
-- ============================================

function Meta(meta)
  -- Only inject for HTML output
  if not quarto.doc.is_format("html") then
    return meta
  end

  -- Check if feature is enabled
  if not meta.reproducible then
    return meta
  end

  if not meta.reproducible.enabled then
    return meta
  end

  -- Get configuration
  local config = get_config(meta)

  -- Extract and validate tier once (used by both URL and HTML generation)
  local tier = get_value(meta.reproducible, config, "tier", "medium")
  local valid_tiers = {light = true, medium = true, heavy = true, gpu = true}
  if not valid_tiers[tier] then
    quarto.log.warning("Invalid tier: " .. tier .. ", using 'medium'")
    tier = "medium"
  end

  -- Build URL with validated tier
  local url = build_onyxia_url(meta, config, tier)

  -- Generate HTML with validated tier
  local html = generate_button_html(url, meta, config, tier)

  -- Inject into document (before body content)
  quarto.doc.include_text("before-body", html)

  return meta
end

-- Export the filter
return {{Meta = Meta}}
