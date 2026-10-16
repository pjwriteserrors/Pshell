# Filemanager – Design Specification

## 1. Vision

Develop a visually distinctive Linux file manager using Qt Quick / QML and, where appropriate, Quickshell integration.

The application must feel like a modern desktop workspace, not a traditional file explorer. Avoid the conventional layout dominated by a permanent folder tree on the left and a plain file list on the right.

**Core principles:**
- Visual-first file browsing
- Modern, elegant, dark interface
- Minimalist layout with rich visual content
- Fast navigation and intuitive interactions
- Smooth, subtle animations
- Keyboard-first productivity
- Responsive layouts and customizable panels

## 2. Visual Design

- Dark navy / charcoal background
- Subtle blue and cyan accent colors
- Translucent surfaces and restrained glass effects
- Rounded cards and panels
- Clear typography and visual hierarchy
- Consistent spacing, padding and corner radii
- Smooth hover, selection and transition animations
- High-quality thumbnails instead of generic file icons wherever possible

Avoid excessive gradients, visual clutter, unnecessary decoration and oversized UI elements.

## 3. Main Interface

### Header
- Global search field
- Command palette shortcut (`Ctrl+K`)
- View mode switcher
- Optional settings and application actions

### Navigation Sidebar
Organize navigation into distinct sections:

- Home
- Recent
- Favorites
- Shared
- Tags
- Local drives and mounted volumes
- Network locations
- Custom collections

The sidebar must be collapsible and should not dominate the available screen space.

### Main Content Area
Use a flexible, card-based layout rather than a permanent table.

Support:
- Folder cards with representative content previews
- Image and video thumbnails
- Document previews and meaningful file-type icons
- Configurable card sizes
- Grid and compact list views
- Sorting, grouping and filtering
- Breadcrumb navigation

### Optional Details Panel
Display:
- Large file preview
- Filename, type and size
- Modification date and dimensions where applicable
- File location
- Tags and metadata
- Contextual actions

The panel must be independently toggleable.

## 4. Three Main Views

### Home – Visual Dashboard
- Project and folder cards
- Recently accessed files
- Visual sections for images, documents and videos
- Favorites and collections
- Quick access to common locations

### Browse – Visual File Explorer
- Thumbnail-based grid
- Flexible card sizes
- Optional grouping by file type, date or tags
- Breadcrumb navigation
- Optional preview and details panel
- Support for conventional list view when needed

### Arrange – File Organization
- Optional dual-pane layout
- Drag-and-drop between locations
- Multi-selection
- Copy, move, rename and delete
- Conflict resolution with clear choices
- Progress queue for file operations
- Safe undo for supported operations

## 5. Essential UX Features

- Global search across filenames and supported metadata
- Quick Preview using the Space key
- Keyboard navigation and shortcuts
- Tabs for multiple locations
- Favorites and virtual collections
- Asynchronous thumbnail generation with caching
- Non-blocking file operations
- Clear progress indicators and error feedback
- Conflict handling for duplicate filenames
- Undo for supported file operations
- Context menus with relevant actions

Virtual collections must reference files without physically moving them.

## 6. Technology and Architecture

- Target platform: Linux desktop
- UI: Qt Quick / QML
- Evaluate whether a standalone Qt 6 application is more appropriate than using Quickshell as the primary application framework.
- Use native filesystem APIs or appropriate Qt facilities for file access.
- Keep filesystem operations and thumbnail generation off the UI thread.
- Separate UI components, filesystem services, thumbnail services and file-operation logic.
- Centralize design tokens for colors, spacing, typography, radii and animation durations.

## 7. Implementation Priorities

**Phase 1 – UI foundation**
- Design system
- Main window and navigation
- Home dashboard
- Visual Browse view
- File and folder cards
- Breadcrumbs and selection states
- Light interaction animations

**Phase 2 – Core functionality**
- Filesystem integration
- Navigation and tabs
- Copy, move, rename and delete
- Search and filtering
- Thumbnail caching
- Quick Preview

**Phase 3 – Advanced features**
- Dual-pane mode
- Virtual collections and tags
- Undo history
- Advanced metadata
- Improved file conflict handling

## 8. Design Acceptance Criteria

- The application must not look like a reskinned Windows Explorer.
- The default experience must prioritize visual content over plain lists.
- The interface must remain usable with large directories.
- Navigation and preview panels must be optional.
- Animations must never block interactions.
- File operations must provide clear feedback and handle errors safely.
- The design must remain consistent across all views.
- The core interface must work well with keyboard and mouse.

**First milestone:** Build a polished, interactive UI prototype for Home and Browse using realistic mock data. Establish the visual language and navigation before implementing the complete filesystem backend.
