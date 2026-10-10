# Textbin design

This document records the product direction, information architecture, and
visual system agreed in October 2026. The mocks it describes live on a shared
canvas: <https://claude.ai/artifact/G3D9FBpjWScRsAdjenHz2j> (pages: Screens,
Logo, Color). Treat this file as the written source of truth and the canvas as
the picture of it; when they disagree, fix whichever is wrong and say so in the
commit.

## North Star

Textbin is the team's trusted scratch space. Anyone in a workspace can get a
snippet from their clipboard to a shareable link in one motion, find it again
later, and always know who can see it. Governance is visible, not hidden.

Ranked ambitions, in order: a team tool with governance; fast enough to be used
as a personal pastebin; API and CLI first for everything the web app does, with
the CLI and separate API docs carrying the infrastructure story.

### Who it is for

1. A team inside a company. The workspace is the unit of identity.
2. A solo developer. The personal workspace is a workspace like any other;
   there is no separate solo mode, only sensible defaults for a team of one.

### What people do most

Sharing with a teammate and stashing for later carry equal weight. They agree
on almost everything and disagree on two defaults, which are therefore
per-workspace settings rather than product decisions:

- default expiry (a team incidents workspace might default to 7 days, a
  personal one to never);
- list ordering (newest first for sharing, pinned and last viewed for stashing).

Long-lived reference documents (runbooks, incident timelines) are out of scope
until the paste can be edited in place with a version history. The one cheap
concession is an optional reference link on a paste so it can point at a ticket
or incident.

## Principles

- **Workspace is home.** The personal workspace is a workspace like any other.
- **The paste is the object.** It has a title, an author, a language, a
  lifecycle, and a plain-language answer to "who can see this". The UUID is
  never the visible identity.
- **Create is fast, find is easy.** Both are first-class surfaces, never one
  crammed above the other.
- **Nothing is lost by accident.** Delete and expiry are one lifecycle with a
  recovery window, then a hard delete.
- **Sharing outward is deliberate.** Only members create pastes. A member may
  share a paste outside the team by making it link-only or public, within what
  the workspace policy allows. There are no guest users.

## Information architecture

- **Home** lands on the last-used workspace, or the personal one on first
  login.
- **One navigation surface per breakpoint.** Desktop: a sidebar holding the
  logo, org switcher, New paste, Search, the workspaces, a single Manage entry,
  and the account menu. Tablet (below about 1024px): the same sidebar as a
  64px rail of initials that expands to an overlay drawer; it never pushes
  content. Phone: a bottom bar with Pastes, New, Search, More. There is no
  separate header.
- **Workspace** has three tabs: Pastes, Deleted, Settings. Members fold into
  Settings.
- **New paste** is its own route with a full-height editor. Title is derived
  from the first line unless typed. Audience is three radio cards; options the
  workspace policy forbids are shown disabled with the reason. Expiry is a
  segmented control with the workspace default preselected and the removal
  date spelled out.
- **Paste detail** leads with the title and a one-sentence audience banner
  that includes the expiry. Primary action is Copy link. Secondary actions:
  copy content, raw, download, duplicate, delete.
- **Deleted** lists removed and expired pastes with the reason, who did it,
  days remaining, Restore, and Delete now. Links to a removed paste stop
  working immediately; the owner sees a restore page. Restoring an expired
  paste clears its expiry.
- **Search** is global across the workspaces you belong to. Header field on
  desktop and tablet, a tab on phone. Excerpts show matched text. Deleted
  pastes and binary files are not searched.
- **Manage** holds Members, Workspaces, Audit log, and Organization settings
  under one entry. The sidebar keeps the workspace list visible while in
  Manage.
- **Account** holds Appearance (theme and mode), Profile, API tokens, and
  Security. Theme is a personal preference, never an org setting; shared
  links always render in the default theme.

### Vocabulary

Four overlapping concepts today (audience, visibility, external sharing
policy, open or private workspace) become three, each explained in the
interface as a sentence:

- **Who can see this** (per paste): everyone in the workspace, anyone with the
  link, or public.
- **Sharing outside the team** (per workspace): members only, members may
  share a link, members may also publish. Tightening it never changes pastes
  already shared.
- **Who can join** (per workspace): anyone in the organization, or invite
  only.

### Lifecycle

Active, then removed (by delete or by expiry), then hard deleted after the
workspace's recovery window. One state machine, one cleaner. Audit entries
survive the hard delete. Removing a member keeps their pastes attributed to
them by default.

## Visual system

### Type

IBM Plex Sans for the interface, IBM Plex Mono for anything the user pasted
and for identifiers. Scale: 28/600 display, 24/600 page title, 18/500 paste
title, 14 body, 13 secondary, 12/600 uppercase section labels, 13px mono on a
22px line for code.

### Spacing and radius

4px base. Radii: 4 chip, 6 kbd, 8 control, 10 card, pill for filters. Controls
are 36px tall on desktop and 40px on tablet and phone.

### Mark and wordmark

The mark is two square brackets with two lines between them, drawn as a
single-weight stroke on a 24-unit grid (stroke 2.75, round caps). It is inline
SVG everywhere and needs no raster asset. The wordmark is `textbin`, lowercase,
Plex Sans 600, tracking -0.025em. Primary lockup is the mark in a tile beside
the word; the gap is one bracket width and clear space is one mark height.
Below 20px the word is dropped. An expressive lockup places the word between
the mark's brackets and is reserved for large sizes.

```svg
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.75"
     stroke-linecap="round" stroke-linejoin="round">
  <path d="M8.5 4H4v16h4.5M15.5 4H20v16h-4.5M9.5 9.5h5M9.5 14.5h3"/>
</svg>
```

### Color

One token set per theme, each with light and dark values where the theme has
both. Neutrals (ground, surface, code, border, three inks), one accent, three
semantic colors (expiring amber, destructive red, success green), six syntax
roles, and six identity pairs for avatars and workspace dots. Every text color
clears 4.5:1 on the surfaces it sits on, in both modes. Identity colors are
assigned by hashing the id so a person keeps their color everywhere.

Themes shipped: Harbor (default, teal-blue on cool neutrals), Paper (warm
neutrals, forest accent), Graphite (monochrome, near-black accent), Midnight
(dark only, navy with sky accent), Terminal (dark only, near-black with green
accent). Each is one CSS custom-property file; a new theme is a pull request,
not a design project. Token values are on the Color page of the canvas.

Harbor light, for reference:

| Token       | Value   |
| ----------- | ------- |
| Ground      | #F4F5F7 |
| Surface     | #FFFFFF |
| Code        | #F8F9FB |
| Border      | #E2E5EA |
| Ink         | #15181E |
| Ink 2       | #4B5362 |
| Ink 3       | #646C7A |
| Accent      | #1D6F8E |
| Expiring    | #9A5B00 |
| Destructive | #B3261E |
| Success     | #1B7F4B |

Harbor dark: ground #0F1115, surface #161A20, code #12151B, border #262B34,
ink #E8EAEE, ink 2 #A3AAB6, ink 3 #8A93A3, accent #5FB3D1 with ink text on
it, expiring #E0A24A, destructive #F08A80, success #6CC39A.

## Sequencing

1. Paste as object: title column, author in the list, derived title fallback,
   optional reference link.
2. Split create from browse; new detail page with Copy link as the primary
   action.
3. Single-nav shell: sidebar, tablet rail, phone bottom bar; home redirects to
   the last-used workspace.
4. Soft-delete lifecycle, Deleted tab, restore, per-workspace retention.
5. Search.
6. Remove guest users and the legacy `/pastes` redirect.
7. Themes: token files, appearance settings, per-user preference.

Steps 1 and 2 change what the product feels like without touching the data
model beyond a title column, which is why they go first. Step 6 is last
because it is a removal and benefits from the rest being in place.
