# Workspaces Branding

## App Icon

### Concept

The icon is a dark rounded square containing a 2x2 grid. Three cells are dark and empty; the bottom-right cell holds a bright green terminal cursor (`>`). One bright element against a dark field.

This directly maps to the core user story: **a portfolio of code repositories with one active terminal session**.

### Design Principles

1. **Minimalist iconography**: Simple geometry, no gradients, no 3D effects. Flat vector style.
2. **Scales to any size**: Recognizable at 16px (dark square, one green dot) through 1024px (full grid detail).
3. **Dark palette**: Charcoal background with a single bright accent. Matches the terminal-first developer aesthetic.
4. **Single focal element**: The green cursor is the only bright element. Everything else recedes.
5. **Metaphor-driven**: Grid = portfolio of repos. Green cell = active workspace. Terminal cursor = this is a terminal app.

### Color Palette

| Element | Color | Hex |
|---------|-------|-----|
| Background | Dark charcoal | `#1e1e2a` (approximate) |
| Grid lines | Subtle gray | `#3a3a4a` (approximate) |
| Empty cells | Near-black | `#252530` (approximate) |
| Active cursor | Mint green | `#4ade80` (approximate) |

### Asset Files

| File | Size | Purpose |
|------|------|---------|
| `icon-concepts/icon-master-1024.png` | 1024x1024 | Master source file |
| `icon-concepts/favicon.ico` | Multi (16-256) | Web favicon |
| `icon-concepts/AppIcon.icns` | Multi (16-1024) | macOS app bundle icon |
| `Sources/.../AppIcon.appiconset/` | 10 PNGs | Xcode asset catalog (built into app) |

### macOS Asset Catalog Sizes

| Filename | Pixels | Scale | Slot |
|----------|--------|-------|------|
| `icon_16x16.png` | 16x16 | 1x | Menu bar, Finder list |
| `icon_16x16@2x.png` | 32x32 | 2x | Menu bar, Finder list (Retina) |
| `icon_32x32.png` | 32x32 | 1x | Finder, Dock (small) |
| `icon_32x32@2x.png` | 64x64 | 2x | Finder, Dock (Retina) |
| `icon_128x128.png` | 128x128 | 1x | Finder preview |
| `icon_128x128@2x.png` | 256x256 | 2x | Finder preview (Retina) |
| `icon_256x256.png` | 256x256 | 1x | Finder |
| `icon_256x256@2x.png` | 512x512 | 2x | Finder (Retina) |
| `icon_512x512.png` | 512x512 | 1x | App Store |
| `icon_512x512@2x.png` | 1024x1024 | 2x | App Store (Retina) |

### Regenerating Icons

From the master 1024px PNG:

```bash
# Resize all asset catalog PNGs
SRC="icon-concepts/icon-master-1024.png"
DEST="Sources/WorkspaceManager/Resources/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512 1024; do
  sips -z $size $size --out "$DEST/icon_${size}.png" "$SRC"
done

# Create .ico (requires ImageMagick)
magick "$SRC" \
  \( -clone 0 -resize 16x16 \) \
  \( -clone 0 -resize 32x32 \) \
  \( -clone 0 -resize 48x48 \) \
  \( -clone 0 -resize 64x64 \) \
  \( -clone 0 -resize 128x128 \) \
  \( -clone 0 -resize 256x256 \) \
  -delete 0 icon-concepts/favicon.ico

# Create .icns (macOS native)
mkdir -p /tmp/AppIcon.iconset
# ... (see sips commands for each size)
iconutil -c icns /tmp/AppIcon.iconset -o icon-concepts/AppIcon.icns
```

## Exploration Process

Seven concepts were generated during the 2026-02-15 design session. The exploration narrowed from three directions to one:

1. **Terminal cursor with fork** (concepts 1) -- Too sparse, no container
2. **Layered windows** (concept 2) -- Clean but didn't communicate "terminal"
3. **Portfolio grid with active terminal** (concepts 3, 4, 7) -- Winner: directly maps the core metaphor

Concept 7 is the refined final version of the portfolio grid direction. All exploration artifacts are preserved in `icon-concepts/`.

### Generation Details

**Model**: OpenAI `gpt-image-1` via `generate_openai.py` (quality: high, size: 1024x1024)

**Prompt** (concept 7, the final icon):

> A macOS app icon on a SOLID BLACK background. The icon is a dark charcoal rounded square with slightly lighter charcoal edges. Inside: a perfectly centered 2x2 grid made of thin subtle gray lines. Three grid cells are dark and empty. The bottom-right cell contains a bright mint-green terminal chevron cursor (>) glowing softly. The green chevron is the ONLY bright element in the entire icon — everything else is dark grays and blacks. This icon represents a developer workspace manager: a portfolio grid of code repositories where one is actively running a terminal session. Style: ultra-minimalist, flat, geometric, no gradients, no 3D, no text. Must be instantly recognizable at 16x16 as a grid with one bright element. Professional, understated, macOS-native feel.

**Iteration notes**: The prompt evolved through 7 rounds. Key learnings:
- Explicitly requesting "SOLID BLACK background" was necessary — the API defaults to light backgrounds
- Referencing specific hex colors helped but wasn't always followed
- Describing the metaphor ("portfolio of repositories where one is active") produced better composition than purely visual descriptions
- Asking for "no text, no letters" was essential to prevent the model from adding labels

## Usage Guidelines

- Always use the provided assets; do not recreate or modify the icon
- The icon works on both light and dark macOS backgrounds (the dark rounded rect provides its own container)
- For web/GitHub, use `favicon.ico` or the 128px PNG
- For README badges or documentation, use `icon_256x256.png`
- The master file for any future re-generation is `icon-concepts/icon-master-1024.png`
