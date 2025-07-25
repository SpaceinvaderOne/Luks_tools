# Responsive WebGUI Plugin Migration Guide

## Table of Contents

- [Why Responsive? The Benefits for Unraid Users & Developers](#why-responsive-the-benefits-for-unraid-users--developers)
- [Prerequisite: How .page Files Are Parsed](#prerequisite-how-page-files-are-parsed-markdown-whitespace-and-structure)
- [Common Bugs in .page Files](#common-bugs-in-page-files-and-how-to-fix-them)
- [Making Wide Tables Responsive](#making-wide-tables-responsive-using-the-tablecontainer-class)
- [Summary](#summary)
- [Quick Fix: Opting Out of Responsive Layout](#quick-fix-opting-out-of-responsive-layout-if-youre-short-on-time)

## Why Responsive? The Benefits for Unraid Users & Developers

Unraid's webGUI has been refactored to support responsive CSS. Here's why this matters:

- **Mobile & Tablet Friendly:** Manage your server from any device, any screen size, no more pinching/zooming required.
- **Consistent Layouts:** No more broken forms or tables on small screens. Everything adapts.
- **Modern Look & Feel:** Cleaner, more professional UI that matches user expectations.

---

## Prerequisite: How .page Files Are Parsed (Markdown, Whitespace, and Structure)

Unraid's plugin system uses `.page` files, which are parsed using a custom Markdown engine. Understanding this is key to writing responsive plugins.

### The Parsing Pipeline

1. **Header Parsing:** The top of the file (before `---`) is parsed as INI for metadata (Title, Menu, etc).
2. **Content Parsing:** The rest is parsed as Markdown, with special handling for translation (`_(text)_`) and definition lists.
3. **PHP Evaluation:** Any PHP code is executed after Markdown is processed.

### Whitespace & Markdown Structure

- **Definition List Syntax:**

  ```markdown
  _(Label)_:
  : <input ...>
  ```

  This is parsed into:

  ```html
  <dl>
    <dt>Label</dt>
    <dd><input ...></dd>
  </dl>
  ```

- **Whitespace is Critical:**
  - The colon (`:`) must be at the start of the line, followed by a space.
  - Indentation or extra spaces can break parsing, causing elements to fall outside the `<dl>` structure.
- **Final Render:**
  - The browser receives a series of `<dl>`, `<dt>`, and `<dd>` elements, which are then styled by CSS.
  - Responsive CSS expects this structure to apply correct flex/grid layouts.

### Block Tags and Markdown Parsing

By default, if you use a `<div>` (or any block-level HTML tag) in your `.page` file, **the contents inside that tag will NOT be parsed as markdown**. The markdown parser treats the contents as raw HTML and leaves them untouched.

**If you want the contents of a `<div>` (or other block tag) to be parsed as markdown, you must add `markdown="1"` to the tag:**

```html
<div>
  _(This will NOT be parsed as markdown)_
  : <input type="text">
</div>
```

**With `markdown="1"`:**

```html
<div markdown="1">
  _(This WILL be parsed as markdown inside the div)_
  : <input type="text">
</div>
```

Example 2 **With `markdown="1"`:**

```html

_(This WILL be parsed as markdown)_
: <div markdown="1">
    _(This WILL be parsed as markdown inside the div)_
    <input type="text">
    <div class="my-custom-element">
      <p>This will not be parsed as markdown.</p>
      <p><?= "This is php shorthand echo without markdown parsing"; ?></p>
      <p><?= _("This is php shorthand echo with translation support and no markdown parsing"); ?></p>
    </div>
</div>
```

This applies to all block-level tags (div, section, article, etc). Use `markdown="1"` if you need markdown parsing inside a custom container.

### Why This Matters

If your markup doesn't follow the expected pattern, the CSS can't do its job. That's when you get broken layouts, giant buttons, or misaligned fields.

---

## Common Bugs in .page Files (and How to Fix Them)

### 1. Large Buttons

**Bug:** Buttons stretch full width, look massive, or break the layout.

![Example: Pool Device Status page with large, stretched Reset button](assets/pool-device-status-bug.png)
*Pool Device Status page before fix: The Reset button is stretched and not visually grouped.*

**Why:**

- On desktop screens, `<dd>` uses `display: flex; flex-direction: column;` (see the responsive CSS). This means every direct child of `<dd>`—including buttons, inputs, spans, etc.—is stacked vertically and stretched to the available width by default.
- If you put a button directly inside `<dd>`, it becomes a flex item and will stretch to fill the column (unless it's inside a `<span>` or similar inline container).
- Old markup:

  ```markdown
  _(Action)_:
  : <input type="button" value="Click Me 1">
  : <input type="button" value="Click Me 2"> <!-- WRONG: likely to break parsing + responsive layout -->
  ```

**Fix:**

- Wrap buttons in a `<span>` (or `<span class="buttons-spaced">` for groups):

  ```markdown
  _(Action)_:
  : <span><input type="button" value="Click Me 1"></span>

  &nbsp;
  : <span><input type="button" value="Click Me 2"></span>

  <!-- or use a button group, explained below -->
  ```

- For button groups:
  - Before:

  ```markdown
  &nbsp;
  : <input type="submit" name="#apply" value="_(Apply)_"><input type="button" value="_(Done)_" onclick="done()">
  ```

  - After:

  ```markdown
  &nbsp;
  : <span class="buttons-spaced">
      <input type="submit" value="Apply">
      <input type="button" value="Done">
    </span>
  ```

### 2. Settings Label + Inputs Are Offset (Whitespace/Parsing Issue)

**Bug:** Labels and inputs don't line up, or inputs appear on a new line, not next to their label.

![Example: Scrub Status page with offset labels and controls](assets/scrub-status-bug.png)
*Scrub Status page before fix: Labels and controls are misaligned due to whitespace/structure issues.*

**Why:**

- Extra spaces, tabs, or missing colons in the Markdown definition list syntax.
- Elements placed outside the `label: content` pattern aren't wrapped in `<dl>`, `<dt>`, `<dd>`. Or potentially two `<dd>` elements adjacent to each other.

**Fix:**

- Make sure every input is inside a definition list and with a line break between each label + content pair:

  ```markdown
  _(Setting One)_:
  : <input type="text" ...>

  _(Setting Two)_:
  : <input type="text" ...>

  _(Setting Three)_:
  : <input type="text" ...>
  ```

- For elements with no label, use `&nbsp;` as the label:

  ```markdown
  &nbsp;
  : <span class="buttons-spaced">...</span>
  ```

- Inspect the page source and clean up whitespace in an attempt to remove rogue elements outside the definition structure.

---

## Making Wide Tables Responsive: Using the TableContainer Class

When you have tables with **a lot of columns** (wide tables) in your plugin, you should wrap them in a special container to ensure they remain usable on all screen sizes. The `TableContainer` class sets a **minimum width** on the table, so it doesn't shrink too small on mobile or narrow windows. This allows users to scroll horizontally to view the entire table, especially when there are many columns.

### How to Use

- For tables with many columns (wide tables), wrap them in a `<div class="TableContainer">`.
- For simple/narrow tables, this wrapper is usually not needed.
- **Test extensively at various screen sizes** and make your decision based on your own content display needs.

### Why?

- Without this wrapper, wide tables may become too small to read or interact with at smaller screen sizes.
- The TableContainer class sets a `min-width` on the table and enables horizontal scrolling, so users can always access all columns, even on mobile.

### Example: Before

```html
<table>
  <thead>
    <tr><th>Col1</th><th>Col2</th><th>Col3</th>...<th>ColN</th></tr>
  </thead>
  <tbody>
    <tr><td>...</td><td>...</td><td>...</td>...<td>...</td></tr>
  </tbody>
</table>
```

### Example: After

```html
<div class="TableContainer">
  <table>
    <thead>
      <tr><th>Col1</th><th>Col2</th><th>Col3</th>...<th>ColN</th></tr>
    </thead>
    <tbody>
      <tr><td>...</td><td>...</td><td>...</td>...<td>...</td></tr>
    </tbody>
  </table>
</div>
```

**Tip:** Only wrap the immediate table element—don't nest TableContainers or wrap unrelated content.

---

## Footer Plugin Integration

### Overview

The footer has been redesigned with responsive capabilities and horizontal scrolling support. Plugin developers need to understand the new footer structure to properly integrate their content.

### Footer Structure

The footer contains two main sections:
- `.footer-left` - Contains system status and notifications (left side on desktop, top on mobile)
- `.footer-right` - Contains copyright, links, and plugin-added content (right side on desktop, bottom on mobile)

### Adding Content to the Footer

**All plugin content should be added to the `.footer-right` element.**

> **Note on Backwards Compatibility**: The element also retains `id="copyright"` for potential backwards compatibility with existing plugins, but **new development should use the `.footer-right` class selector** as the preferred method for DOM injection.

#### JavaScript Integration

```javascript
// Preferred method: Use the class selector
$('.footer-right').append('<span>Your plugin content</span>');

// Legacy method (for backwards compatibility only)
$('#copyright').append('<span>Your plugin content</span>');
```

#### Important Considerations

1. **No Line Breaks**: Content added to `.footer-right` will never break to a new line
2. **Horizontal Scrolling**: When content overflows, the footer will automatically enable horizontal scrolling
3. **Responsive Behavior**:
   - **Mobile**: Footer stacks vertically (`.footer-left` on top, `.footer-right` below)
   - **Desktop**: Footer displays side-by-side (`.footer-left` on left, `.footer-right` on right)
4. **Content Styling**: Added elements should use `white-space: nowrap` if they contain text that shouldn't wrap

#### Example

```javascript
// Good: Add a status indicator
$('.footer-right').append('<span class="plugin-status">Plugin: Active</span>');

// Good: Add a clickable element
$('.footer-right').append('<span onclick="openPluginSettings()">⚙️ Settings</span>');

// Good: Add multiple related elements
$('.footer-right').append(`
    <span class="plugin-info">
        <span>Version: 1.0</span>
        <span>Status: OK</span>
    </span>
`);
```

### CSS Considerations

The footer uses flexbox layout with the following key properties:
- `flex-wrap: nowrap` - Prevents content from wrapping to new lines
- `overflow-x: auto` - Enables horizontal scrolling when needed
- `gap: 1rem` - Provides consistent spacing between elements

Your plugin content will automatically inherit these behaviors when added to `.footer-right`.

---

## Summary

- Wrap button groups in `<span class="buttons-spaced">`.
- Watch your whitespace and colons—Markdown parsing is strict.
- Test on mobile and desktop to catch layout issues early.
- Add footer content to `.footer-right` element for proper responsive behavior.

---

## Quick Fix: Opting Out of Responsive Layout (If You're Short on Time)

**⚠️ WARNING: This is a temporary stopgap solution. You should plan to migrate to the responsive system for the best user experience and future compatibility.**

If you can't dedicate time right now to update your plugin for the new responsive system, you can temporarily opt out of the responsive CSS for your page. This will preserve the legacy layout and prevent your page from breaking, but **it is not a long-term solution** and you should plan to migrate to the responsive system for the best user experience and future compatibility.

There are two options

### Option 1: Custom pages that don't utilize markdown parsing

Add the following to the top (YAML header) of your `.page` file:

```yaml
ResponsiveLayout="false"
```

**Example:**

```yaml
Title="Add VM"
Tag="clipboard"
Cond="(pgrep('libvirtd')!==false)"
Markdown="false"
ResponsiveLayout="false"
---
```

See `AddVM.page` and `UpdateVM.page` for real-world examples of this approach.

Instead of using the `dl > dt + dd` structure, these pages use a different layout system that doesn't utilize markdown parsing.

#### What This Does

- Wraps your page content in a `<div class="content--non-responsive">` that forces a **minimum width of 1200px** via CSS. This keeps your layout looking like the old (non-responsive) UI, even on smaller screens.
- Your page content will not adapt to mobile or small window sizes—it will always be at least 1200px wide, and users may need to scroll horizontally on small devices.
- **This is a stopgap.** You should still plan to migrate to the responsive system for the best user experience and future compatibility.

### Option 2: Wrap your custom elements in a `<div class="content--non-responsive">` to force a min width of 1200px

Let's say you have a `*.page` for your plugin. It has some settings that follow the standard `label: content` pattern that are get parsed into a `<dl>`, `<dt>`, `<dd>` structure.

But also on this page you have custom element(s) that are not parsed by the markdown parser and wrapped in the `dl > dt + dd` structure. Instead you maybe have a `<div>` that contains your plugin specific content. And instead that plugin specific content you have a complex layout.

Before example:

```html
_(Setting One)_:
: <input type="text" ...>

<div class="plugin-element-one">
  <header>
    <h2>Plugin Element</h2>
  </header>
  <div>
    <p>This is a plugin element</p>
  </div>
</div>

_(Setting Two)_:
: <input type="number" ...>

<div class="plugin-element-two">
  <header>
    <h2>Plugin Element</h2>
  </header>
  <div>
    <p>This is a plugin element</p>
  </div>
</div>
```

After example:

```html
_(Setting One)_:
: <input type="text" ...>

<!-- option 1 -->
<div class="content--non-responsive">
  <div class="plugin-element-one">
    ...
  </div>
</div>

<!-- option 2 -->
<div class="plugin-element-one content--non-responsive">
  ...
</div>

_(Setting Two)_:
: <input type="number" ...>

<!-- option 1 -->
<div class="content--non-responsive">
  <div class="plugin-element-one">
    ...
  </div>
</div>

<!-- option 2 -->
<div class="plugin-element-one content--non-responsive">
  ...
</div>
```

The route you choose will depend on your specific use case. Explore the available options.

If these specific examples don't apply to your plugin, you can still opt out of the responsive layout by adding `ResponsiveLayout="false"` to the top (YAML header) of your `.page` file. Or come up with your own solution for your specific use case.

However, we highly recommend you migrate to the responsive system for the best user experience and future compatibility.
