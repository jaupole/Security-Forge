/*
 * Proposal Forge — "Boilerplate Library" plugin (right panel).
 *
 * Lists the organization's reusable BOILERPLATE assets (title + a short text
 * preview). Clicking a block inserts its content at the cursor via the plugin
 * API. Boilerplate content may be rich HTML or plain text:
 *   - rich HTML  → executeMethod("PasteHtml", [html]) — pastes formatted content
 *                  at the cursor / over the selection.
 *   - plain text → executeMethod("PasteText", [text]) — pastes literal text,
 *                  preserving line breaks (no markup interpretation).
 * Both method names/signatures verified against api.onlyoffice.com (plugin
 * executeMethod reference + the "Get and paste html" sample plugin, 2026-07-05);
 * PasteText is the same method the sibling "Proposal Fields" plugin uses.
 *
 * This is a BUILT-IN Document Server plugin: it ships inside the DS image under
 * sdkjs-plugins/pf-library/ and loads same-origin from the DS, so this frame has
 * NO query string. Launch context (which project/org + how to reach Proposal
 * Forge) arrives as a short-lived, project+org-scoped token in the plugin
 * OPTIONS the editor passes: PF sets editorConfig.plugins.options['asc.{…}'] =
 * { ctx, api }, and the DS hands the plugin a single merged options object at
 * window.Asc.plugin.info.options (options.all + options[guid] flattened — see
 * ONLYOFFICE sdkjs/common/plugins.js ~L732 for the merge and
 * common/plugins/plugin_base.js ~L641/L644 for info / info.options; verified
 * 2026-07-05). That is the ONLY channel — the token is presented to the plugin
 * data route via `Authorization: Bearer`, never the URL path. No session cookie
 * is used: the token is the whole capability, CORS-scoped to the DS origin.
 */
(function () {
  'use strict'

  var PLUGIN_GUID = 'asc.{14945233-53ED-4077-8E68-484B1785752A}'

  var listEl = null
  var searchEl = null
  var allItems = []
  var ctx = null

  function trimSlashes(s) {
    return String(s || '').replace(/\/+$/, '')
  }

  /** Read the launch context from the plugin options the editor passes to this
   *  built-in plugin. The DS flattens editorConfig.plugins.options.all +
   *  options[guid] into ONE object exposed at window.Asc.plugin.info.options, so
   *  the merged shape carries { ctx, api } directly; the GUID-keyed / `all`
   *  probes below are belt-and-suspenders for a DS build that surfaced the raw
   *  (unmerged) shape instead. Primary channel for a built-in plugin. */
  function ctxFromOptions() {
    try {
      var info = window.Asc && window.Asc.plugin && window.Asc.plugin.info
      var opts = info && info.options
      if (!opts || typeof opts !== 'object') return null
      var scoped =
        (opts[PLUGIN_GUID] && typeof opts[PLUGIN_GUID] === 'object' && opts[PLUGIN_GUID]) ||
        (opts.all && typeof opts.all === 'object' && opts.all) ||
        opts
      if (scoped && scoped.ctx) {
        return { token: String(scoped.ctx), api: trimSlashes(scoped.api) || window.location.origin }
      }
    } catch (e) {
      /* ignore */
    }
    return null
  }

  function setState(message, isError) {
    if (!listEl) return
    listEl.textContent = ''
    var div = document.createElement('div')
    div.className = 'pf-state' + (isError ? ' pf-error' : '')
    div.textContent = message
    listEl.appendChild(div)
  }

  /** Does the content carry an HTML element tag (→ paste as HTML)? */
  function looksLikeHtml(s) {
    return /<([a-z][a-z0-9]*)\b[^>]*>/i.test(String(s || ''))
  }

  /** Plain-text preview from possibly-HTML content. Regex strip (not innerHTML)
   *  so no untrusted markup is ever parsed into the plugin DOM. */
  function previewText(content) {
    var s = String(content || '').replace(/<[^>]*>/g, ' ')
    s = s
      .replace(/&nbsp;/g, ' ')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&amp;/g, '&')
    return s.replace(/\s+/g, ' ').trim()
  }

  function insertItem(content) {
    var c = String(content || '')
    if (!c) return
    try {
      if (looksLikeHtml(c)) {
        window.Asc.plugin.executeMethod('PasteHtml', [c])
      } else {
        window.Asc.plugin.executeMethod('PasteText', [c])
      }
    } catch (e) {
      /* editor not ready — nothing to do */
    }
  }

  function makeItem(item) {
    var btn = document.createElement('button')
    btn.type = 'button'
    btn.className = 'pf-item'
    btn.title = 'Insert “' + (item.title || 'boilerplate') + '”'

    var label = document.createElement('span')
    label.className = 'pf-label'
    label.textContent = item.title || 'Untitled'
    btn.appendChild(label)

    if (item._preview) {
      var preview = document.createElement('span')
      preview.className = 'pf-preview'
      preview.textContent = item._preview
      btn.appendChild(preview)
    }

    btn.addEventListener('click', function () {
      insertItem(item.content)
    })
    return btn
  }

  function render(filterText) {
    if (!listEl) return
    var needle = (filterText || '').trim().toLowerCase()
    listEl.textContent = ''

    var items = allItems.filter(function (it) {
      if (!needle) return true
      return (
        (it.title || '').toLowerCase().indexOf(needle) !== -1 ||
        (it._preview || '').toLowerCase().indexOf(needle) !== -1
      )
    })

    if (items.length === 0) {
      setState(
        needle ? 'No boilerplate matches “' + filterText + '”.' : 'No boilerplate available.',
        false,
      )
      return
    }

    var box = document.createElement('div')
    box.className = 'pf-group'
    for (var i = 0; i < items.length; i++) box.appendChild(makeItem(items[i]))
    listEl.appendChild(box)
  }

  function loadItems() {
    var url = ctx.api + '/api/v1/onlyoffice/library'
    // credentials omitted on purpose: this is a cross-origin/third-party frame
    // with no session — the Bearer token is the entire authorization. It rides
    // the Authorization HEADER, never the URL path, so it stays out of ingress
    // access logs (token-in-URL leak fix). Requires PF ≥ sec/token-url-transport.
    fetch(url, {
      method: 'GET',
      credentials: 'omit',
      mode: 'cors',
      headers: { Authorization: 'Bearer ' + ctx.token },
    })
      .then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status)
        return res.json()
      })
      .then(function (body) {
        var data = (body && body.data) || []
        allItems = data.map(function (it) {
          return { id: it.id, title: it.title, content: it.content, _preview: previewText(it.content) }
        })
        render(searchEl ? searchEl.value : '')
      })
      .catch(function (err) {
        setState('Could not load boilerplate (' + (err && err.message ? err.message : 'error') + ').', true)
      })
  }

  function boot() {
    listEl = document.getElementById('pf-list')
    searchEl = document.getElementById('pf-search')
    if (searchEl) {
      searchEl.addEventListener('input', function () {
        render(searchEl.value)
      })
    }
    // Options are the ONLY launch channel: this built-in plugin loads same-origin
    // from the DS with no query string, and the context (incl. the capability
    // token) comes from the server-signed editor-config. A query-string fallback
    // was removed — it would have posted the Bearer token to a caller-supplied
    // host if the frame were ever loaded via a crafted URL (dead code as
    // deployed, but a needless token-exfil surface).
    ctx = ctxFromOptions()
    if (!ctx) {
      // No launch context (e.g. a read-only/viewer session that carries no
      // plugin options): sit idle rather than erroring — there is simply
      // nothing to insert here.
      setState('Open a proposal to load boilerplate.', false)
      return
    }
    loadItems()
  }

  // ── Obligatory ONLYOFFICE plugin events ──────────────────────────────────
  window.Asc = window.Asc || {}
  window.Asc.plugin = window.Asc.plugin || {}

  // init fires once the editor <-> plugin bridge is ready; window.Asc.plugin.info
  // (and info.options) is populated by then, so the options channel can be read
  // here.
  window.Asc.plugin.init = function () {
    boot()
  }

  // Panel plugins have no footer buttons; -1 is the panel close affordance.
  window.Asc.plugin.button = function (id) {
    if (id === -1 && typeof window.Asc.plugin.executeCommand === 'function') {
      window.Asc.plugin.executeCommand('close', '')
    }
  }
})()
