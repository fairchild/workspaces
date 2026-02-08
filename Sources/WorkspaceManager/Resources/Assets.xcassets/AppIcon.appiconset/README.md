# App Icon Requirements

This directory requires PNG icons at the following sizes for macOS:

| Filename              | Pixel Size | Point Size | Scale |
|-----------------------|------------|------------|-------|
| icon_16x16.png        | 16x16      | 16x16      | 1x    |
| icon_16x16@2x.png     | 32x32      | 16x16      | 2x    |
| icon_32x32.png        | 32x32      | 32x32      | 1x    |
| icon_32x32@2x.png     | 64x64      | 32x32      | 2x    |
| icon_128x128.png      | 128x128    | 128x128    | 1x    |
| icon_128x128@2x.png   | 256x256    | 128x128    | 2x    |
| icon_256x256.png      | 256x256    | 256x256    | 1x    |
| icon_256x256@2x.png   | 512x512    | 256x256    | 2x    |
| icon_512x512.png      | 512x512    | 512x512    | 1x    |
| icon_512x512@2x.png   | 1024x1024  | 512x512    | 2x    |

## Generating Icons from a Master Image

If you have a 1024x1024 master icon, you can generate all sizes with ImageMagick:

```bash
# Install ImageMagick if needed
brew install imagemagick

# Generate all required sizes from a 1024x1024 master
MASTER="icon_master_1024x1024.png"

convert $MASTER -resize 16x16   icon_16x16.png
convert $MASTER -resize 32x32   icon_16x16@2x.png
convert $MASTER -resize 32x32   icon_32x32.png
convert $MASTER -resize 64x64   icon_32x32@2x.png
convert $MASTER -resize 128x128 icon_128x128.png
convert $MASTER -resize 256x256 icon_128x128@2x.png
convert $MASTER -resize 256x256 icon_256x256.png
convert $MASTER -resize 512x512 icon_256x256@2x.png
convert $MASTER -resize 512x512 icon_512x512.png
convert $MASTER -resize 1024x1024 icon_512x512@2x.png
```

## Icon Design Guidelines

Follow Apple's Human Interface Guidelines for macOS app icons:
- Use a simple, recognizable shape
- Employ a consistent visual style
- Consider how the icon looks at small sizes (16x16)
- Use subtle gradients and shadows for depth
- Avoid too much detail that gets lost at small sizes

Reference: https://developer.apple.com/design/human-interface-guidelines/app-icons

## Placeholder Icons

Until custom icons are created, the app will use the default macOS app icon.
To test with placeholder icons, you can generate solid-color placeholders:

```bash
# Generate placeholder icons (blue squares)
for size in 16 32 64 128 256 512 1024; do
    convert -size ${size}x${size} xc:#007AFF placeholder_${size}.png
done
```
