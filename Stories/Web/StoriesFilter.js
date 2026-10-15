/* Runs in a WKContentWorld isolated from Instagram's JavaScript globals.
   No fetch, private API, cookie access, input values, or extracted media. */
(() => {
  "use strict";

  const storyPath = /^\/stories\/([A-Za-z0-9._]{1,30})(?:\/[0-9]+)?\/?$/;
  const authRoots = ["/accounts/login", "/accounts/password/reset", "/accounts/onetap",
    "/accounts/confirm_email", "/auth_platform", "/challenge", "/checkpoint", "/consent"];
  const excluded = "article, aside, nav, header, [role='feed'], [role='navigation']";
  const messageEditors = "textarea, [contenteditable='true'], [contenteditable='plaintext-only']";
  const messageHistory = "[role='log'], [role='grid']";
  const messagingModes = new Set(["inbox", "conversation", "messageCompose"]);
  const markerAttributes = ["data-stories-item", "data-stories-branch", "data-stories-viewer", "data-stories-scroller",
    "data-stories-messages", "data-stories-messages-hidden"];

  function route(url) {
    if (url.protocol !== "https:" || !["instagram.com", "www.instagram.com"].includes(url.hostname)
        || url.username || url.password || (url.port && url.port !== "443")
        || url.pathname.includes("%") || url.pathname.includes("\\")) return "blocked";
    const path = url.pathname;
    if (path === "/") return "home";
    if (/^\/direct\/inbox\/?$/.test(path)) return "inbox";
    if (/^\/direct\/t\/[0-9]+\/?$/.test(path)) return "conversation";
    if (/^\/direct\/new\/?$/.test(path)) return "messageCompose";
    const match = path.match(storyPath);
    if (match && !["highlights", "archive", "create"].includes(match[1].toLowerCase())) return "story";
    if (authRoots.some(root => path === root || path.startsWith(root + "/"))) return "authentication";
    return "blocked";
  }

  function install({ document, window, currentURL, report, viewerWaitMs = 12000 }) {
    let lastState = "";
    let lastLocation = "";
    let disposed = false;
    let homePositionReset = false;
    let layoutTicks = 0;
    let viewerPendingSince = null;
    let homeViewerIntent = null;
    let shownViewer = null;
    let viewerMissingSince = null;
    let storyFinished = false;
    let replyBar = null;
    let hiddenReactionPanels = [];
    let messagesPendingSince = null;
    let messagesSnapshot = null;
    let staleMessagesSnapshot = null;
    let messageDialogIntent = false;
    let controlledMessagePanels = new Set();
    const historyRevisions = new WeakMap();
    let locationID = "";
    let locationScope = "";
    const viewport = window.visualViewport;
    const style = document.createElement("style");
    style.id = "stories-filter-style";
    style.textContent = `
      html:not([data-stories-mode="authentication"]) body,
      html:not([data-stories-mode="authentication"]) body * {
        visibility: hidden !important;
      }
      html:not([data-stories-mode="authentication"]) body { background: #f6f5f0 !important; }
      html[data-stories-mode="home"] body *:not([data-stories-branch]):not([data-stories-item]):not([data-stories-item] *) {
        display: none !important;
      }
      html[data-stories-mode="home"] [data-stories-item],
      html[data-stories-mode="home"] [data-stories-item] * { visibility: visible !important; }
      /* WebKit needs the scrolling box itself to be visible to accept swipes,
         even when its child Story buttons are already visible. */
      html[data-stories-mode="home"] [data-stories-scroller] { visibility: visible !important; }
      /* Preserve Instagram's carousel heights, overflow, and positioning. Its slides
         can be absolute-positioned: forcing an ancestor to height:auto collapses it. */
      html[data-stories-mode="story"] [data-stories-viewer],
      html[data-stories-mode="story"] [data-stories-viewer] * { visibility: visible !important; }
      html:is([data-stories-mode="inbox"], [data-stories-mode="conversation"], [data-stories-mode="messageCompose"])
        [data-stories-messages],
      html:is([data-stories-mode="inbox"], [data-stories-mode="conversation"], [data-stories-mode="messageCompose"])
        [data-stories-messages] * { visibility: visible !important; }
      html:is([data-stories-mode="inbox"], [data-stories-mode="conversation"], [data-stories-mode="messageCompose"])
        [data-stories-messages-hidden],
      html:is([data-stories-mode="inbox"], [data-stories-mode="conversation"], [data-stories-mode="messageCompose"])
        [data-stories-messages-hidden] * {
        visibility: hidden !important;
        pointer-events: none !important;
      }
      /* Outside the viewer, the default visibility rule still hides everything.
         Don't display:none article/nav: Instagram can use them inside a Story. */
      html:is([data-stories-mode="story"], [data-stories-mode="conversation"]) [data-stories-reply] {
        translate: 0 var(--stories-reply-offset, 0px) !important;
      }
      html[data-stories-mode="story"] [data-stories-reactions-hidden],
      html[data-stories-mode="story"] [data-stories-reactions-hidden] * {
        visibility: hidden !important;
        pointer-events: none !important;
      }
    `;

    function opaqueLocationID() {
      const bytes = new Uint8Array(16);
      if (window.crypto?.getRandomValues) window.crypto.getRandomValues(bytes);
      else for (let index = 0; index < bytes.length; index++) bytes[index] = Math.floor(Math.random() * 256);
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
      const hex = [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("");
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    }

    function sendState(state) {
      const scope = currentURL().href;
      if (scope !== locationScope) {
        locationScope = scope;
        locationID = opaqueLocationID();
      }
      // This opaque token lets native code reject a queued state after an SPA
      // navigation. It never includes a URL, participant, draft, or message data.
      report(state, locationID);
    }

    function emit(state) {
      if (state !== lastState || currentURL().href !== lastLocation) { lastState = state; sendState(state); }
    }

    function clearMarkers() {
      for (const attr of markerAttributes) {
        document.querySelectorAll(`[${attr}]`).forEach(node => node.removeAttribute(attr));
      }
    }

    function markItem(node) {
      node.setAttribute("data-stories-item", "");
      for (let parent = node.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
        parent.setAttribute("data-stories-branch", "");
      }
    }

    function markStoryScroller(item) {
      for (let parent = item.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
        // Stop before a shared page/feed surface. Only expose a carousel containing
        // recognized cards; its unmarked children remain hidden by the normal filter.
        if (parent.matches(excluded) || parent.querySelector(excluded)) break;
        if (parent.clientWidth > 0 && parent.scrollWidth > parent.clientWidth + 1
            && /^(auto|scroll)$/.test(window.getComputedStyle(parent).overflowX)
            && parent.querySelectorAll("[data-stories-item]").length > 1) {
          parent.setAttribute("data-stories-scroller", "");
          return;
        }
      }
    }

    function isStoryLink(node, url) {
      try { return route(new URL(node.getAttribute("href"), url)) === "story"; }
      catch { return false; }
    }

    function storyCard(control) {
      // Links may be empty overlays over sibling avatars/name labels. Reveal that
      // small card as a unit without moving React-owned nodes or exposing the tray's siblings.
      let fallback = control;
      for (let parent = control.parentElement, depth = 0;
           parent && parent !== document.body && depth < 3;
           parent = parent.parentElement, depth++) {
        if (!parent.matches("div, li, button, [role='button'], [role='listitem'], [role='menuitem']")) break;
        if (parent.matches(excluded) || parent.querySelector(excluded + ", video, input, textarea, select, iframe, h1, h2, h3")) break;
        const otherControls = [...parent.querySelectorAll("a[href], button, [role='button']")]
          .some(node => node !== control && !control.contains(node) && !node.contains(control));
        if (otherControls || parent.querySelectorAll("img").length > 2 || parent.textContent.trim().length > 128) break;
        if (parent.querySelector("img, canvas")) {
          fallback = parent;
          if (parent.textContent.trim() || parent.matches("li, [role='listitem'], [role='menuitem']")) return parent;
        }
      }
      return fallback;
    }

    function renderedInViewport(node) {
      return window.getComputedStyle(node).visibility === "visible" && hasViewportArea(node);
    }

    // Geometry-only checks also work before our fail-closed stylesheet reveals
    // the candidate. Account for both the window and nested scroll clipping.
    function hasViewportArea(node) {
      const rect = node.getBoundingClientRect();
      let left = Math.max(0, rect.left), top = Math.max(0, rect.top);
      let right = Math.min(window.innerWidth, rect.right), bottom = Math.min(window.innerHeight, rect.bottom);
      for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
        const css = window.getComputedStyle(ancestor);
        if (css.display === "none" || Number(css.opacity) === 0 || css.contentVisibility === "hidden") return false;
        if (ancestor !== node) {
          const clip = ancestor.getBoundingClientRect();
          if (/^(hidden|clip|auto|scroll)$/.test(css.overflowX)) {
            left = Math.max(left, clip.left); right = Math.min(right, clip.right);
          }
          if (/^(hidden|clip|auto|scroll)$/.test(css.overflowY)) {
            top = Math.max(top, clip.top); bottom = Math.min(bottom, clip.bottom);
          }
        }
      }
      return right - left > 1 && bottom - top > 1;
    }

    function hasVisibleArtwork(item) {
      // aria-label and a nonempty link hitbox aren't pixels. Require text or artwork,
      // accounting for clipping/opacity rather than just a nonempty bounding box.
      const content = [item, ...item.querySelectorAll("*")].filter(node =>
        node.matches("img, canvas, svg") || [...node.childNodes].some(child => child.nodeType === 3 && child.textContent.trim()));
      return content.some(renderedInViewport);
    }

    function reportHomeReadiness() {
      const visible = [...document.querySelectorAll("[data-stories-item]")].some(hasVisibleArtwork);
      if (visible) storyFinished = false;
      emit(visible ? "home" : storyFinished ? "story-ended" : "unavailable");
    }

    function hasLayout(node) {
      const rect = node.getBoundingClientRect();
      if (rect.width <= 1 || rect.height <= 1 || rect.right <= 0 || rect.bottom <= 0
          || rect.left >= window.innerWidth || rect.top >= window.innerHeight) return false;
      return hasRenderedBox(node);
    }

    function hasRenderedBox(node) {
      const rect = node.getBoundingClientRect();
      if (rect.width <= 1 || rect.height <= 1) return false;
      for (let parent = node; parent; parent = parent.parentElement) {
        const css = window.getComputedStyle(parent);
        if (css.display === "none" || Number(css.opacity) === 0 || css.contentVisibility === "hidden") return false;
      }
      // Ignore visibility here: our own fail-closed stylesheet deliberately hides candidates.
      return true;
    }

    function isScreenSurface(node) {
      const rect = node.getBoundingClientRect();
      return rect.width >= Math.min(240, window.innerWidth * 0.55)
        && rect.height >= Math.min(320, window.innerHeight * 0.5);
    }

    function isOverlay(node) {
      return isScreenSurface(node) && /^(fixed|absolute)$/.test(window.getComputedStyle(node).position);
    }

    function destination(anchor, url) {
      try { return route(new URL(anchor.getAttribute("href"), url)); }
      catch { return "blocked"; }
    }

    function isGlobalNavigation(node, url) {
      const destinations = [...node.querySelectorAll("a[href]")].map(anchor => {
        try { return new URL(anchor.getAttribute("href"), url).pathname; }
        catch { return ""; }
      });
      const globalLinks = destinations.filter(path => path === "/"
        || /^\/(explore|reels|accounts\/edit)\/?$/.test(path));
      const directLinks = [...node.querySelectorAll("a[href]")]
        .some(anchor => messagingModes.has(destination(anchor, url)));
      // A messaging sidebar can itself be a nav/aside. Identify the global menu
      // by its destinations instead of hiding all semantic navigation elements.
      return globalLinks.length >= 2 || (globalLinks.length > 0 && !directLinks);
    }

    function findPlainMessageHistory(node, editor) {
      const draft = editor.getBoundingClientRect();
      // Desktop Direct uses deeply nested plain divs for both the history and
      // composer. Identify the separate vertical history above the draft, never
      // the inbox sidebar, a draft scroller, or a horizontal control strip.
      return [...node.querySelectorAll("div")].find(history => {
        if (!hasLayout(history) || !hasViewportArea(history)
            || history.contains(editor) || history.querySelector(messageEditors)
            || history.closest("nav, aside, header, [role='navigation'], [role='feed'], [role='menu'], [role='listbox']")
            || !/^(auto|scroll)$/.test(window.getComputedStyle(history).overflowY)) return false;
        const rect = history.getBoundingClientRect();
        const overlap = Math.min(rect.right, draft.right) - Math.max(rect.left, draft.left);
        return rect.height >= 120 && rect.width >= Math.min(200, window.innerWidth * 0.4)
          && rect.bottom <= draft.top + 8 && overlap >= Math.min(rect.width, draft.width) * 0.5;
      }) || null;
    }

    function messageStructure(node, mode, url) {
      const links = [...node.querySelectorAll("a[href]")].filter(hasLayout);
      const threads = links.filter(anchor => destination(anchor, url) === "conversation");
      const compose = links.filter(anchor => destination(anchor, url) === "messageCompose");
      const inbox = links.filter(anchor => destination(anchor, url) === "inbox");
      // The keyboard can put a still-mounted composer outside the layout viewport.
      // Keep recognizing it so the geometry-only adjustment can lift the whole bar.
      const editor = [...node.querySelectorAll(messageEditors)].find(hasRenderedBox) || null;
      const historySelector = mode === "inbox" && !editor ? "[role='log']" : messageHistory;
      const semanticHistory = [...node.querySelectorAll(historySelector)].find(hasLayout) || null;
      const plainHistory = mode === "conversation" && editor && !semanticHistory
        ? findPlainMessageHistory(node, editor) : null;
      const history = semanticHistory || plainHistory;
      const recipient = [...node.querySelectorAll("input:not([type]), input[type='text'], input[type='search'], input[role='combobox'], input[role='searchbox']")]
        .find(hasLayout) || null;
      const heading = [...node.querySelectorAll("h1, h2, h3, [role='heading']")].find(hasLayout);
      const controls = [...node.querySelectorAll("button, [role='button']")].filter(hasLayout);
      const avatarRows = controls.filter(control => {
        if (control.querySelector("input, textarea, [contenteditable], video, canvas, article, [role='feed']")) return false;
        const avatar = [...control.querySelectorAll("img")].find(hasLayout);
        if (!avatar) return false;
        const rect = avatar.getBoundingClientRect();
        if (rect.width > 96 || rect.height > 96) return false;
        if (control.closest("ul, ol, [role='list'], [role='menu'], [role='grid']")) return true;
        // Mobile React inboxes also use plain div router buttons, without links
        // or list roles. Recognize a wide, compact avatar row with adjacent labels;
        // small Story/Notes tiles and avatar-only loading placeholders don't qualify.
        const row = control.getBoundingClientRect();
        const labels = [...control.querySelectorAll("span, div")].filter(label =>
          !label.contains(avatar) && hasLayout(label)
          && [...label.childNodes].some(child => child.nodeType === 3 && child.textContent.trim()));
        return row.width >= Math.min(200, window.innerWidth * 0.6)
          && row.height <= 128 && labels.length >= 2
          && ![...control.querySelectorAll("a[href]")].some(anchor => !messagingModes.has(destination(anchor, url)));
      });
      const emptyIllustration = [...node.querySelectorAll("svg")].some(svg => {
        const rect = svg.getBoundingClientRect();
        return hasLayout(svg) && rect.width >= 48 && rect.height >= 48;
      });
      const composeControl = controls.some(control => control.querySelector("svg") && !avatarRows.includes(control));
      let recognized = false;
      if (mode === "inbox") {
        // Do not reveal an old conversation left mounted while navigating back.
        // Desktop inbox lists can be a smaller nav/aside beside that conversation.
        recognized = !editor && !history && (threads.length > 0
          || (compose.length > 0 && !!heading)
          || (!!heading && avatarRows.length > 0
            && (avatarRows.length >= 2 || compose.length > 0 || composeControl))
          || (!!heading && controls.length > 0 && emptyIllustration)
          || (!!heading && controls.length > 0 && !!node.querySelector("[role='status']")
            && !!node.querySelector("svg, [role='tablist']")));
      } else if (mode === "conversation") {
        recognized = !!editor && ((!!history && (!plainHistory || (!!heading && controls.length >= 2)))
          || (inbox.length > 0 && !!heading && controls.length >= 2));
      } else if (mode === "messageCompose") {
        // Recipient search is an input, rather than the textarea/contenteditable
        // message draft in a stale thread. Labels and headings may be localized.
        recognized = !!recipient && controls.length > 0
          && (!!heading || inbox.length > 0 || node.matches("[role='dialog'], [aria-modal='true']"));
      }
      return { root: node, mode, editor, history, plainHistory: !!plainHistory, recipient, recognized };
    }

    function safeMessageSurface(node, url, history = null) {
      if (node === document.body || !hasLayout(node)
          || node.closest("[role='feed']") || node.querySelector("[role='feed']")
          || node.closest("article:not([role='log']):not([role='grid'])")) return false;
      // Shared-post cards can be part of a recognized history. An ordinary feed
      // article outside the history must never broaden the messaging surface.
      if ([...node.querySelectorAll("article")].some(article =>
        !article.closest(messageHistory) && !history?.contains(article))) return false;
      return !node.matches("nav, aside, header, [role='navigation']") || !isGlobalNavigation(node, url);
    }

    function findMessageSurface(mode, url) {
      const candidates = new Set(document.querySelectorAll("main, [role='main'], [role='dialog'], [aria-modal='true']"));
      const seeds = [...document.querySelectorAll(messageEditors + ", input:not([type]), input[type='text'], input[type='search'], input[role='combobox'], input[role='searchbox']"),
        ...[...document.querySelectorAll("a[href]")].filter(anchor => messagingModes.has(destination(anchor, url))),
        ...[...document.querySelectorAll("button, [role='button']")].filter(control => control.querySelector("img"))];
      for (const seed of seeds) {
        for (let parent = seed.parentElement, depth = 0;
             parent && parent !== document.body && depth < (mode === "conversation" ? 24 : 8);
             parent = parent.parentElement, depth++) candidates.add(parent);
      }
      const matches = [...candidates].map(node => messageStructure(node, mode, url))
        .filter(candidate => candidate.recognized && safeMessageSurface(candidate.root, url, candidate.history));
      // An inferred history needs its dedicated chat container. Enclosing main
      // and app shells can also contain a sidebar or unrelated plain-div content.
      const plainChats = matches.filter(candidate => candidate.plainHistory);
      if (plainChats.length) {
        return plainChats.find(candidate => !plainChats.some(child => child !== candidate
          && candidate.root.contains(child.root))) || null;
      }
      // Prefer Instagram's dedicated semantic surface over an enclosing app shell.
      const dialogs = matches.filter(candidate => candidate.root.matches("[role='dialog'], [aria-modal='true']"));
      const mains = matches.filter(candidate => candidate.root.matches("main, [role='main']"));
      const surfaces = dialogs.length ? dialogs : mains.length ? mains : matches;
      return surfaces.find(candidate => !surfaces.some(parent => parent !== candidate && parent.root.contains(candidate.root))) || null;
    }

    function snapshotMessages(candidate) {
      return { ...candidate,
        historyChildren: candidate.history ? [...candidate.history.childNodes] : [],
        historyRevision: candidate.history ? historyRevisions.get(candidate.history) || 0 : 0,
        rootChildren: [...candidate.root.childNodes] };
    }

    function revealMessagePanels(root, mode, url) {
      if (!messageDialogIntent) return;
      const emojiOnly = label => label.length <= 24 && /\p{Extended_Pictographic}/u.test(label)
        && !/[^\p{Extended_Pictographic}\p{Emoji_Modifier}\uFE0F\u200D\s]/u.test(label);
      for (const panel of document.querySelectorAll("[role='dialog'], [aria-modal='true'], [role='listbox']")) {
        if (panel === root || root.contains(panel) || !safeMessageSurface(panel, url)) continue;
        const compose = mode === "inbox" && messageStructure(panel, "messageCompose", url).recognized;
        const emojiControls = mode === "conversation" ? [...panel.querySelectorAll("button, [role='button']")]
          .filter(control => emojiOnly(control.getAttribute("aria-label") || control.querySelector("img[alt]")?.getAttribute("alt") || "")) : [];
        const attachment = mode === "conversation" && panel.querySelector("input[type='file']");
        // Only reveal message-specific portals, or a panel explicitly related to
        // an original Instagram control. Arbitrary dialogs remain fail-closed.
        if (compose || attachment || emojiControls.length >= 3 || controlledMessagePanels.has(panel.id)) {
          panel.setAttribute("data-stories-messages", "");
        }
      }
    }

    function freshMessageSurface(candidate) {
      const previous = staleMessagesSnapshot;
      if (!previous || candidate.root !== previous.root) return true;
      if (candidate.mode === "inbox") return previous.mode !== "inbox" && !candidate.editor && !candidate.history;
      if (candidate.mode === "messageCompose") {
        return candidate.recipient !== previous.recipient;
      }
      if (candidate.editor !== previous.editor || candidate.history !== previous.history) return true;
      if (candidate.history && (historyRevisions.get(candidate.history) || 0) !== previous.historyRevision) return true;
      const children = candidate.history ? [...candidate.history.childNodes] : [...candidate.root.childNodes];
      const previousChildren = candidate.history ? previous.historyChildren : previous.rootChildren;
      return children.length !== previousChildren.length || children.some((child, index) => child !== previousChildren[index]);
    }

    function updateMessages(mode, url) {
      const candidate = findMessageSurface(mode, url);
      const waitingForReplacement = !!staleMessagesSnapshot;
      const busy = candidate && (candidate.root.matches("[aria-busy='true']")
        // Instagram retains a progressbar above the scrolled message history
        // while fetching older messages. It must not block an available thread.
        || [...candidate.root.querySelectorAll("[role='progressbar'], [aria-busy='true']")].some(hasViewportArea));
      if (candidate && freshMessageSurface(candidate)
          && (!busy || (!waitingForReplacement && messagesSnapshot?.root === candidate.root))) {
        candidate.root.setAttribute("data-stories-messages", "");
        candidate.root.querySelectorAll("nav, aside, header, [role='navigation']").forEach(node => {
          const unrelatedAside = node.matches("aside")
            && !messageStructure(node, mode, url).recognized
            && !node.querySelector(messageEditors + ", " + messageHistory + ", input[type='search']")
            && ![...node.querySelectorAll("a[href]")].some(anchor => messagingModes.has(destination(anchor, url)));
          if (isGlobalNavigation(node, url) || unrelatedAside) node.setAttribute("data-stories-messages-hidden", "");
        });
        if (renderedInViewport(candidate.root)) {
          revealMessagePanels(candidate.root, mode, url);
          messagesSnapshot = snapshotMessages(candidate);
          staleMessagesSnapshot = null;
          messagesPendingSince = null;
          emit(mode === "messageCompose" ? "message-compose" : mode);
          return;
        }
        candidate.root.removeAttribute("data-stories-messages");
      }
      messagesPendingSince ??= window.performance.now();
      emit(window.performance.now() - messagesPendingSince < viewerWaitMs ? "messages-loading" : "messages-unavailable");
    }

    function findViewer(overlayOnly = false) {
      const media = [...document.querySelectorAll("video, img")].filter(node => {
        if (node.closest("[role='feed'], aside, [data-stories-item]")) return false;
        const rect = node.getBoundingClientRect();
        // Exclude avatars and tray thumbnails from generic viewer detection.
        return hasLayout(node) && rect.width >= 120 && rect.height >= 160;
      });
      const candidates = new Set(document.querySelectorAll("[role='dialog'], [aria-modal='true'], main, [role='main']"));
      for (const content of media) {
        for (let parent = content.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
          if (isScreenSurface(parent)) candidates.add(parent);
        }
      }
      const matches = [...candidates].filter(node => {
        if (node === document.body || !hasLayout(node)
            || node.closest("[role='feed'], aside, nav, [role='navigation']")
            || node.querySelector("[role='feed']")) return false;
        const modal = node.matches("[role='dialog'], [aria-modal='true']");
        const overlay = isOverlay(node);
        if (overlayOnly && !modal && !overlay) return false;
        // Don't mistake the home feed left behind by a SPA transition for the viewer.
        if (!modal && !overlay && (node.closest("article") || node.querySelector("article"))) return false;
        const primaryMedia = media.some(content => node.contains(content));
        if (modal) return primaryMedia;
        const controls = node.querySelectorAll("button, [role='button'], input, textarea").length;
        // Native mobile viewers can be plain divs, with localized or unlabelled controls.
        return primaryMedia && isScreenSurface(node)
          && (overlay || controls >= 2 || (node.matches("main, [role='main']") && controls >= 1));
      });
      // Prefer a dedicated modal/overlay over an enclosing application shell.
      // Within that surface, retain siblings such as navigation and close controls.
      const modals = matches.filter(node => node.matches("[role='dialog'], [aria-modal='true']"));
      const overlays = matches.filter(isOverlay);
      const surfaces = modals.length ? modals : overlays.length ? overlays : matches;
      return surfaces.find(node => !surfaces.some(parent => parent !== node && parent.contains(node))) || null;
    }

    function finishStory(url) {
      homeViewerIntent = null;
      shownViewer = null;
      viewerMissingSince = null;
      viewerPendingSince = null;
      storyFinished = true;
      // Reuse an already mounted tray. Otherwise ask native code to load the fixed
      // home URL, including when Instagram leaves the completed Story's URL behind.
      if (route(url) === "home") revealHome(url);
      else emit("story-ended");
    }

    function reportViewerPending(url) {
      if (viewerPendingSince === null) viewerPendingSince = window.performance.now();
      if (window.performance.now() - viewerPendingSince < viewerWaitMs) emit("story-loading");
      // A completed viewer may leave its empty shell mounted. Give media replacement
      // the normal loading window before returning home; unopened Stories still fail.
      else if (shownViewer) finishStory(url);
      else emit("story-unavailable");
    }

    function revealViewer(viewer) {
      viewer.setAttribute("data-stories-viewer", "");
      shownViewer = viewer;
      viewerMissingSince = null;
      viewerPendingSince = null;
      emit("story");
    }

    function updateViewer(url, overlayOnly = false) {
      const viewer = findViewer(overlayOnly);
      if (viewer) { revealViewer(viewer); return; }
      // A disappearing viewer is an exit only after it actually displayed a Story.
      // Brief unmount/remount transitions between slides must be allowed to settle.
      if (shownViewer && (!shownViewer.isConnected || !hasLayout(shownViewer))) {
        viewerMissingSince ??= window.performance.now();
        if (window.performance.now() - viewerMissingSince >= 450) {
          finishStory(url);
          return;
        }
      } else viewerMissingSince = null;
      reportViewerPending(url);
    }

    function resetReplyPosition() {
      hiddenReactionPanels.forEach(node => node.removeAttribute("data-stories-reactions-hidden"));
      hiddenReactionPanels = [];
      if (!replyBar) return;
      replyBar.removeAttribute("data-stories-reply");
      replyBar.style.removeProperty("--stories-reply-offset");
      replyBar = null;
    }

    function hideQuickReactions(viewer, editor) {
      // Recognize the emoji grid structurally, independent of the heading's language.
      // Only inspect control labels, never the draft inside the focused editor.
      const emojiOnly = text => text.length <= 24 && /\p{Extended_Pictographic}/u.test(text)
        && !/[^\p{Extended_Pictographic}\p{Emoji_Modifier}\uFE0F\u200D\s]/u.test(text);
      const controls = [...new Set([...viewer.querySelectorAll("button, [role='button'], span, img[alt]")]
        .filter(node => !node.contains(editor) && !editor.contains(node)
          && !node.closest("textarea, input, [contenteditable='true'], [contenteditable='plaintext-only']")
          && emojiOnly(node.matches("img") ? node.getAttribute("alt") || "" : node.textContent.trim()))
        .map(node => node.closest("button, [role='button']") || node))]
        .filter((node, _, nodes) => !nodes.some(child => child !== node && node.contains(child)));
      const panels = new Set();
      for (const control of controls) {
        let panel = null;
        for (let parent = control.parentElement; parent && parent !== viewer; parent = parent.parentElement) {
          const rect = parent.getBoundingClientRect();
          if (parent.contains(editor) || rect.height > Math.min(320, window.innerHeight * 0.7)
              || parent.querySelector("video, canvas, input, textarea, [contenteditable], article, a[href]")
              || [...parent.querySelectorAll("button, [role='button']")]
                .some(button => !controls.some(node => button === node || button.contains(node)))
              || [...parent.querySelectorAll("img")].some(img => !emojiOnly(img.getAttribute("alt") || ""))) break;
          if (rect.height > 0 && controls.filter(node => parent.contains(node)).length >= 3) panel = parent;
        }
        if (panel) panels.add(panel);
      }
      hiddenReactionPanels = [...panels].filter(node => ![...panels].some(parent => parent !== node && parent.contains(node)));
      hiddenReactionPanels.forEach(node => node.setAttribute("data-stories-reactions-hidden", ""));
    }

    function keepReplyVisible() {
      // Only inspect geometry in an already-recognized Story or conversation.
      // Instagram still owns the editor, draft, send action, and scrolling history.
      const mode = document.documentElement.getAttribute("data-stories-mode");
      if (mode !== "story" && mode !== "conversation") return;
      const editor = document.activeElement;
      if (!editor?.matches("textarea, input:not([type]), input[type='text'], [contenteditable='true'], [contenteditable='plaintext-only']")) return;
      const viewer = editor.closest(mode === "story" ? "[data-stories-viewer]" : "[data-stories-messages]");
      if (!viewer) return;
      if (mode === "story") hideQuickReactions(viewer, editor);
      let bar = editor;
      // Include the adjacent Send control, without lifting media or the entire viewer.
      for (let parent = editor.parentElement; parent && parent !== viewer; parent = parent.parentElement) {
        const rect = parent.getBoundingClientRect();
        const largeContent = mode === "story" ? "video, img, canvas, article, [role='feed']"
          : "video, iframe, article, [role='feed'], [role='log'], [role='grid']";
        if (rect.height > 160 || parent.querySelector(largeContent)) break;
        if (rect.height > 0) bar = parent;
        if (parent.matches("form")) break;
      }
      const rect = bar.getBoundingClientRect();
      const top = viewport?.offsetTop || 0;
      const bottom = Math.min(window.innerHeight, top + (viewport?.height || window.innerHeight));
      const shift = Math.min(0, bottom - 12 - rect.bottom);
      if (shift >= 0 || rect.height > bottom - top - 24) return;
      replyBar = bar;
      bar.style.setProperty("--stories-reply-offset", `${shift}px`);
      bar.setAttribute("data-stories-reply", "");
    }

    function revealHome(url) {
      document.documentElement.setAttribute("data-stories-mode", "home");
      const links = [...document.querySelectorAll("a[href]")]
        .filter(node => !node.closest(excluded) && isStoryLink(node, url));
      const buttons = [...document.querySelectorAll("button, [role='button']")]
        .filter(node => !node.closest(excluded) && node.querySelector("img")
          && (/\b(story|stories|historia|historias)\b/i.test(node.getAttribute("aria-label") || "")
            || (node.querySelector("canvas") && node.closest("ul, ol, [role='list'], [role='menu']"))));
      const items = [...new Set([...links, ...buttons].map(storyCard))];
      items.forEach(markItem);
      items.forEach(markStoryScroller);
      if (items.length && !homePositionReset) {
        window.scrollTo(0, 0);
        homePositionReset = true;
      }
      reportHomeReadiness();
    }

    function apply(force = false) {
      if (disposed || !document.documentElement) return;
      // A focus/click microtask or native refresh may run before the observer's
      // callback. Drain its pending records before disconnecting, so a retained
      // history wrapper's text replacement cannot lose its freshness signal.
      const mutations = [...(Array.isArray(force) ? force : []), ...observer.takeRecords()];
      if (mutations.length) {
        const histories = new Set([messagesSnapshot?.history, staleMessagesSnapshot?.history].filter(Boolean));
        for (const history of histories) {
          // React can retain both the log wrapper and its children while replacing
          // nested message text. Observe that change without reading the text.
          if (mutations.some(record => (record.type === "childList" || record.type === "characterData")
              && (record.target === history || history.contains(record.target)))) {
            historyRevisions.set(history, (historyRevisions.get(history) || 0) + 1);
          }
        }
      }
      if (force === true) lastState = "";
      // Disconnect while marking the DOM so our own changes cannot create an observer loop.
      observer.disconnect();
      resetReplyPosition();
      if (!style.isConnected) document.documentElement.appendChild(style);
      const url = currentURL();
      const mode = route(url);
      const returnedHome = mode === "home" && lastLocation && route(new URL(lastLocation)) === "story";
      if (url.href !== lastLocation) {
        const previous = lastLocation ? new URL(lastLocation) : null;
        if (messagingModes.has(mode) && previous && messagingModes.has(route(previous))
            && url.pathname.replace(/\/$/, "") !== previous.pathname.replace(/\/$/, "")) {
          staleMessagesSnapshot = messagesSnapshot;
          messagesPendingSince = window.performance.now();
          messageDialogIntent = false;
          controlledMessagePanels = new Set();
        }
        viewerPendingSince = null;
        shownViewer = null;
        viewerMissingSince = null;
        storyFinished = false;
      }
      if (mode !== "home") homeViewerIntent = null;
      if (!messagingModes.has(mode)) {
        messagesPendingSince = null;
        messagesSnapshot = null;
        staleMessagesSnapshot = null;
        messageDialogIntent = false;
        controlledMessagePanels = new Set();
      }
      document.documentElement.setAttribute("data-stories-mode", mode === "home" && homeViewerIntent ? "story" : mode);
      clearMarkers();
      if (mode !== "home") homePositionReset = false;

      if (mode === "authentication") {
        // Do not inspect login forms, inputs, or authentication challenges.
        emit("authentication");
      } else if (mode === "home") {
        if (returnedHome) {
          finishStory(url);
        } else if (homeViewerIntent) {
          updateViewer(url, true);
        } else {
          viewerPendingSince = null;
          revealHome(url);
        }
      } else if (mode === "story") {
        if (storyFinished) emit("story-ended");
        else updateViewer(url);
      } else if (messagingModes.has(mode)) {
        updateMessages(mode, url);
      } else {
        viewerPendingSince = null;
        emit("blocked");
      }
      lastLocation = url.href;
      keepReplyVisible();
      observer.observe(document.documentElement, {
        childList: true, characterData: true, subtree: true, attributes: true,
        attributeFilter: ["href", "role", "aria-label", "aria-busy", "aria-controls", "class", "style", "hidden", "src"]
      });
    }

    const observer = new window.MutationObserver(apply);
    function onFocusChange() { window.queueMicrotask(apply); }
    // Capture internal links before Instagram's router can expose a forbidden page.
    function onClick(event) {
      if (messagingModes.has(route(currentURL())) && event.target.closest?.("[data-stories-messages]")) {
        messageDialogIntent = true;
        const control = event.target.closest?.("button, [role='button'], [aria-controls]");
        const controlledIDs = control?.getAttribute("aria-controls")?.split(/\s+/).filter(Boolean) || [];
        controlledIDs.forEach(id => controlledMessagePanels.add(id));
        // Portal dialogs may mount asynchronously after the original click action.
        window.queueMicrotask(apply);
      }
      const anchor = event.target.closest?.("a[href]");
      if (anchor) {
        let url;
        try { url = new URL(anchor.getAttribute("href"), currentURL()); } catch { return; }
        const instagram = url.hostname === "instagram.com" || url.hostname.endsWith(".instagram.com");
        const linkShim = url.protocol === "https:" && url.hostname === "l.instagram.com";
        if ((instagram && !linkShim && route(url) === "blocked") || !["https:", "http:"].includes(url.protocol)) {
          event.preventDefault();
          event.stopImmediatePropagation();
          sendState("restricted-link");
          return;
        }
        if (route(url) !== "story") return;
      }
      if (route(currentURL()) === "home" && event.target.closest?.("[data-stories-item]")) {
        homeViewerIntent = true;
        shownViewer = null;
        viewerMissingSince = null;
        storyFinished = false;
        viewerPendingSince = window.performance.now();
        emit("story-loading");
        // Let Instagram's original event handler run before changing the layout mode.
        window.queueMicrotask(apply);
      }
    }

    document.addEventListener("click", onClick, true);
    window.addEventListener("popstate", apply);
    window.addEventListener("pageshow", apply);
    window.addEventListener("resize", apply);
    viewport?.addEventListener("resize", apply);
    viewport?.addEventListener("scroll", apply);
    document.addEventListener("focusin", onFocusChange);
    document.addEventListener("focusout", onFocusChange);
    document.addEventListener("load", apply, true);
    // Isolated worlds cannot safely patch Instagram's history object. Observe URL
    // changes without touching its JavaScript; mutations are handled before paint.
    const timer = window.setInterval(() => {
      if (currentURL().href !== lastLocation || !style.isConnected) apply();
      // CSS animations, font loading, and responsive layout can change visibility
      // without a DOM mutation. Never leave a blank page in the native ready state.
      else if (lastState === "story-loading") apply();
      else if (lastState === "messages-loading") apply();
      else if (++layoutTicks % 6 === 0) {
        if (homeViewerIntent || route(currentURL()) === "story") apply();
        else if (route(currentURL()) === "home") reportHomeReadiness();
        else if (messagingModes.has(route(currentURL()))) apply();
      }
    }, 150);
    apply();

    function dispose() {
      disposed = true;
      observer.disconnect();
      resetReplyPosition();
      clearMarkers();
      style.remove();
      document.documentElement.removeAttribute("data-stories-mode");
      window.clearInterval(timer);
      document.removeEventListener("click", onClick, true);
      window.removeEventListener("popstate", apply);
      window.removeEventListener("pageshow", apply);
      window.removeEventListener("resize", apply);
      viewport?.removeEventListener("resize", apply);
      viewport?.removeEventListener("scroll", apply);
      document.removeEventListener("focusin", onFocusChange);
      document.removeEventListener("focusout", onFocusChange);
      document.removeEventListener("load", apply, true);
    }
    function isCurrentLocation(id) {
      return !disposed && id === locationID && locationScope === currentURL().href;
    }
    return Object.freeze({ refresh: apply, dispose, isCurrentLocation });
  }

  globalThis.StoriesFilter = Object.freeze({ install, route });
})();
