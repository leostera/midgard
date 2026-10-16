---
name: Midgard local worker platform
description: A compact local workspace for creating, deploying and routing Elixir workers.
colors:
  rail: "#222235"
  rail-selected: "#393353"
  primary: "#6845c4"
  primary-deep: "#5132a5"
  ink: "#222539"
  muted: "#606175"
  divider: "#e3e4ec"
  quiet-field: "#f8f8fb"
  work-surface: "#ffffff"
  deployed: "#276e54"
  error: "#9e273f"
typography:
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "23px"
    fontWeight: 710
    lineHeight: 1.15
    letterSpacing: "-0.025em"
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "13px"
    lineHeight: 1.5
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "11px"
    fontWeight: 690
  code:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, monospace"
    fontSize: "13px"
    lineHeight: 1.65
rounded:
  control: "5px"
  panel: "6px"
spacing:
  compact: "7px"
  control: "13px"
  panel: "17px"
  workspace: "34px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.work-surface}"
    rounded: "{rounded.control}"
    padding: "8px 13px"
  button-primary-hover:
    backgroundColor: "{colors.primary-deep}"
    textColor: "{colors.work-surface}"
    rounded: "{rounded.control}"
    padding: "8px 13px"
  search-input:
    backgroundColor: "{colors.work-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "0 12px"
---

# Design System: Midgard local worker platform

## Overview

**Creative North Star: "The Working Registry"**

This is a trusted-local development control plane, not a marketing dashboard. A charcoal-purple navigation rail stays visible while an uninterrupted white work surface holds either a dense workers table or a source/deployment task. The user-selected Contrast rail direction privileges actual status, routes and invocation history over ornamental metrics. The native Isolate boundary is conveyed through precise text and genuine states, not diagrams pretending to monitor what the platform cannot measure.

**Key Characteristics:**
- Full-height dark rail beside a light, compact working area; no global top bar.
- Purple distinguishes navigation and actions; green is reserved for an admitted deployment.
- Real rows, narrow rules and tabular figures; no sample traffic in the shipped application.

## Colors

The rail owns the dark field. White owns the working area, violet owns actionable focus and green names only a real live worker. Error red appears only with an actual failure.

**The Real-State Rule.** Never show deployed styling for a draft or an invocation count without recorded local traffic. Unavailable telemetry is marked unavailable, not silently reset to zero.

## Typography

System sans is the workhorse for titles, controls and table labels. The title is intentionally modest; the tabular invocation column is heavier but not larger. Uppercase ten-pixel labels belong only to navigation groups and table headers. Monospace is for source, route prefixes and machine identifiers, never for decorative atmosphere.

## Layout

The shell has a 224px sticky left rail and a fluid main column. Main content begins near the top, with 34px lateral breathing room, a compact heading/action row, then filters immediately over the table. Rows are approximately 52px tall; the table pages at 25 workers. At 1060px the route column drops; at 680px the rail narrows to 64px and keeps an accessible Workers link while the table retains worker, status and invocation columns. Creation and editor views replace main content without remounting navigation. The source textarea scrolls horizontally rather than breaking code at phone width.

## Elevation & Depth

Flat by design. Single-pixel borders, selected fills and the dark/light region split separate layers; no resting drop shadows.

## Shapes

Controls and selected navigation use restrained five-pixel corners. Content panels use six-pixel corners. Status is a small dot paired with a word, never a color-only signal.

## Components

- **Navigation:** Compute is a group label and Workers is its only shipped destination. Active state uses a muted purple fill and a small violet marker. The footer links the checked-out Midgard commit to GitHub; it never masquerades as a deployment-health indicator or lists worker instances.
- **Table:** A ruled header and thin row dividers carry name, real status, count, last invocation and route prefix. Sort links, status filters, search and pagination are server-rendered and usable without JavaScript. The worker name and Open link lead to the same editor.
- **Buttons and inputs:** Purple fill for the primary action; white or quiet-field for secondary controls. Search and form fields retain explicit labels and visible purple keyboard focus.
- **Source and deployment:** Creation compiles and admits the starter before opening the worker detail view. The detail view leads with a callable example, curl command, deployment age, invocation count and shipment identity. Below it, a deep-rail-colored CodeMirror surface adds Elixir syntax, gutters, active-line focus and search; a plain textarea remains the no-JavaScript fallback. Failed edits leave the prior URL visible and working.

## Do's and Don'ts

### Do:
- **Do** show counts per worker across redeployments and label the scope as local HTTP routing.
- **Do** retain a usable draft, empty-result and compiler-error state with the same shell.
- **Do** keep search, sorting, filters and navigation keyboard accessible at desktop and phone widths.

### Don't:
- **Don't** place worker names in the global sidebar or invent other product destinations.
- **Don't** add a global header or oversized display typography to the operating workspace.
- **Don't** imply that the browser's source is compiled inside the serving VM or that a draft URL is callable.
