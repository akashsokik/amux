# amux Design System

## Philosophy

Linear-inspired dark theme with layered depth, cool-toned grays, and indigo accents. Background hierarchy creates visual depth between surfaces. System font (SF Pro) for UI text. Crisp, high-contrast text. Every surface has a distinct tonal value to establish spatial relationships.

## Color Palette

### Background Hierarchy

| Token        | Hex       | Usage                                    |
|--------------|-----------|------------------------------------------|
| background   | `#08090a` | Main window, terminal panes (near-black) |
| panelBg      | `#0f1011` | Panel backgrounds                        |
| elevated     | `#141516` | Elevated surfaces, inputs                |
| sidebarBg    | `#1c1c1f` | Sidebar (lighter than main, creates depth) |
| hoverBg      | `#232326` | Hover state backgrounds                  |
| activeBg     | `#28282c` | Active/selected backgrounds              |

### Text Hierarchy

| Token          | Hex       | Usage                           |
|----------------|-----------|----------------------------------|
| primaryText    | `#f7f8f8` | Active items, main content       |
| secondaryText  | `#d0d6e0` | Inactive items, metadata         |
| tertiaryText   | `#8a8f98` | Labels, placeholders             |
| quaternaryText | `#62666d` | Disabled, section headers        |

### Borders

| Token             | Value             | Usage                        |
|-------------------|-------------------|------------------------------|
| borderPrimary     | `#23252a`         | Default dividers/borders     |
| borderSecondary   | `#34343a`         | Emphasis borders, hover dividers |
| borderTranslucent | `white alpha 0.05`| Subtle overlays              |

### Accent

| Token    | Hex       | Usage                          |
|----------|-----------|--------------------------------|
| accent   | `#5e6ad2` | Active indicator, focus ring   |
| accentUI | `#7170ff` | Active icons, brighter accent  |

### Interactive States

| State    | Token    | Usage                       |
|----------|----------|-----------------------------|
| hover    | hoverBg  | Hover on rows/buttons       |
| active   | activeBg | Selected/active row bg      |

## Typography

UI text uses system font (SF Pro via `NSFont.systemFont`). Terminal content uses Ghostty-configured font.

| Element          | Size   | Weight   |
|------------------|--------|----------|
| Session name     | 13px   | medium   |
| Sidebar header   | 10.5px | semibold |
| Shortcut hint    | 11px   | mono medium |
| Add label        | 12px   | medium   |
| Header kern      | 1.8    | --       |

## Corner Radii

| Token   | Value | Usage                    |
|---------|-------|--------------------------|
| badge   | 4px   | Shortcut badges          |
| element | 6px   | Row highlights, buttons  |
| card    | 8px   | Cards, panels            |

## Animation

| Token    | Value  | Usage                    |
|----------|--------|--------------------------|
| quick    | 0.1s   | Micro-interactions       |
| standard | 0.25s  | Sidebar toggle, panels   |

## Layout Constants

| Element             | Value   |
|---------------------|---------|
| Sidebar width       | 220px   |
| Sidebar row height  | 32px    |
| Bottom bar height   | 40px    |
| Divider visual      | 1px     |
| Divider hit target  | 7px     |
| Focus border width  | 2px     |
| Min window size     | 600x400 |
| Toolbar button size | 30x24   |

## Sidebar

- Background `#1c1c1f` (lighter than main `#08090a` for depth separation)
- "SESSIONS" header: 10.5px semibold, `#62666d`, kern 1.8, uppercase
- 1px divider below header at `#23252a`
- Session rows: 32px tall, 2px intercell spacing
- Active row: `#28282c` bg, `#f7f8f8` text, indigo pill indicator
- Inactive row: transparent bg, `#d0d6e0` text
- Hover: `#232326` bg (visible but subtle)
- Rows have 6px corner radius
- Terminal icon: 13pt symbol, 16x16 view, `#62666d` inactive / `#7170ff` active
- Shortcut badge: 11px mono medium, `#62666d`, 20x20, 4px radius, `white 0.05` bg
- Bottom bar: 40px, plus icon 12pt medium, `#8a8f98` tint
- "New Session" label: 12px medium, `#8a8f98`
- Right edge: 1px divider at `#23252a`

## Pane Dividers

- 1px visual line centered in 7px hit target
- Default: `#23252a`
- Hover/drag: `#34343a`
- Cursor changes to resize on hover

## Window Chrome

- Dark aqua appearance
- Transparent titlebar, hidden title
- Full-size content view
- Background: `#08090a` (near-black)
- Unified compact toolbar style
- Toolbar buttons: 14pt medium symbol, `#8a8f98` tint, 30x24 frame

## Focus Ring

- 2px solid indigo (`#5e6ad2`) border on focused terminal pane
- No border on unfocused panes

## Principles

1. **Layered depth** -- surfaces at different tonal values create spatial hierarchy
2. **Cool-toned** -- all grays have a slight blue/cool shift, not warm
3. **Indigo accent** -- `#5e6ad2` for focus/active, `#7170ff` for icons
4. **Solid colors** -- interactive states use solid bg tokens, not opacity overlays
5. **Crisp text** -- `#f7f8f8` primary is near-white for high readability
6. **Compact** -- 32px rows, tight padding, no wasted space
7. **Depth separation** -- sidebar lighter than main bg (opposite of typical dark themes)
