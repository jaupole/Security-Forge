/*
 * Proposal Forge — "Boilerplate Library" plugin (right panel).
 *
 * Lists the organization's reusable text blocks — Boilerplate and Past
 * Performance Library items that have content — grouped by type, filterable
 * by tag chip and by text search (title, tags, preview). Clicking a block
 * inserts its content at the cursor via the plugin API. Content may be rich
 * HTML or plain text:
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
 * 2026-07-05). That is the PRIMARY channel; a query-string read is kept only as
 * a fallback for a URL-loaded variation. No session cookie is used: the token
 * is the whole capability, and the endpoint is CORS-scoped to the DS origin.
 */
(function () {
  'use strict'

  var PLUGIN_GUID = 'asc.{14945233-53ED-4077-8E68-484B1785752A}'

  var listEl = null
  var searchEl = null
  var chipsEl = null
  var allItems = []
  var activeTag = null
  var ctx = null
  // New Boilerplate form (shown only when the launch context says the session
  // may create; the server enforces the token's own claim).
  var newToggleEl = null
  var newEl = null
  var newTitleEl = null
  var newContentEl = null
  var newStateEl = null
  var newSaveBtn = null
  var saving = false

  var TYPE_LABELS = { BOILERPLATE: 'Boilerplate', PAST_PERFORMANCE: 'Past Performance' }

  function trimSlashes(s) {
    return String(s || '').replace(/\/+$/, '')
  }

  /** Read the launch context from this frame's own query string. */
  function ctxFromQuery() {
    try {
      var q = new URLSearchParams(window.location.search)
      var token = q.get('ctx')
      if (!token) return null
      var api = q.get('api')
      return { token: token, api: trimSlashes(api) || window.location.origin, canCreate: false }
    } catch (e) {
      return null
    }
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
        return {
          token: String(scoped.ctx),
          api: trimSlashes(scoped.api) || window.location.origin,
          // UI hint only: the server enforces the token's own claim.
          canCreate: scoped.canCreate === true,
        }
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

    if (item.tags && item.tags.length) {
      var tagRow = document.createElement('span')
      tagRow.className = 'pf-tags'
      for (var t = 0; t < item.tags.length; t++) {
        var chip = document.createElement('span')
        chip.className = 'pf-tag'
        chip.textContent = item.tags[t]
        tagRow.appendChild(chip)
      }
      btn.appendChild(tagRow)
    }

    btn.addEventListener('click', function () {
      insertItem(item.content)
    })
    return btn
  }

  function makeChip(label, value) {
    var chip = document.createElement('button')
    chip.type = 'button'
    chip.className = 'pf-chip' + (activeTag === value ? ' pf-chip-on' : '')
    chip.textContent = label
    chip.addEventListener('click', function () {
      activeTag = value
      renderChips()
      render(searchEl ? searchEl.value : '')
    })
    return chip
  }

  /** One chip per distinct tag across all blocks, plus All. Hidden when untagged. */
  function renderChips() {
    if (!chipsEl) return
    chipsEl.textContent = ''
    var seen = {}
    var tags = []
    for (var i = 0; i < allItems.length; i++) {
      var its = allItems[i].tags || []
      for (var j = 0; j < its.length; j++) {
        if (!seen[its[j]]) {
          seen[its[j]] = true
          tags.push(its[j])
        }
      }
    }
    if (tags.length === 0) {
      chipsEl.style.display = 'none'
      return
    }
    tags.sort(function (a, b) {
      return a.localeCompare(b)
    })
    chipsEl.style.display = ''
    chipsEl.appendChild(makeChip('All', null))
    for (var k = 0; k < tags.length; k++) chipsEl.appendChild(makeChip(tags[k], tags[k]))
  }

  function matchesTag(it) {
    if (activeTag === null) return true
    var its = it.tags || []
    for (var i = 0; i < its.length; i++) if (its[i] === activeTag) return true
    return false
  }

  function matchesText(it, needle) {
    if (!needle) return true
    if ((it.title || '').toLowerCase().indexOf(needle) !== -1) return true
    if ((it._preview || '').toLowerCase().indexOf(needle) !== -1) return true
    var its = it.tags || []
    for (var i = 0; i < its.length; i++) if (its[i].toLowerCase().indexOf(needle) !== -1) return true
    return false
  }

  function render(filterText) {
    if (!listEl) return
    var needle = (filterText || '').trim().toLowerCase()
    listEl.textContent = ''

    var items = allItems.filter(function (it) {
      return matchesTag(it) && matchesText(it, needle)
    })

    if (items.length === 0) {
      setState(
        allItems.length === 0
          ? 'No blocks yet. Add Boilerplate or Past Performance items with text under Libraries → Documents.'
          : 'No blocks match.',
        false,
      )
      return
    }

    // Grouped by type, in a fixed order; items within a group keep the
    // server's title order.
    var order = ['BOILERPLATE', 'PAST_PERFORMANCE']
    for (var g = 0; g < order.length; g++) {
      var type = order[g]
      var inGroup = items.filter(function (it) {
        return it.assetType === type
      })
      if (inGroup.length === 0) continue
      var heading = document.createElement('div')
      heading.className = 'pf-heading'
      heading.textContent = TYPE_LABELS[type] || type
      listEl.appendChild(heading)
      var box = document.createElement('div')
      box.className = 'pf-group'
      for (var i = 0; i < inGroup.length; i++) box.appendChild(makeItem(inGroup[i]))
      listEl.appendChild(box)
    }
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
          return {
            id: it.id,
            title: it.title,
            // Older PF builds send no type/tags: treat as untagged boilerplate.
            assetType: it.assetType || 'BOILERPLATE',
            tags: Array.isArray(it.tags) ? it.tags : [],
            content: it.content,
            _preview: previewText(it.content),
          }
        })
        renderChips()
        render(searchEl ? searchEl.value : '')
      })
      .catch(function (err) {
        setState('Could not load the Library (' + (err && err.message ? err.message : 'error') + ').', true)
      })
  }

  // ── New Boilerplate ──────────────────────────────────────────────────────
  // Save reusable text to the org Library without leaving the editor: a title
  // plus content, which can be the document's current selection. POSTs with
  // the same bearer token; the server accepts it only for a token minted for
  // an edit session by a user who may create assets (DRAFTER+).
  function setNewState(message, isError) {
    if (!newStateEl) return
    newStateEl.textContent = message || ''
    newStateEl.className = 'pf-new-state' + (isError ? ' pf-error' : '')
  }

  function showNewForm(show) {
    if (!newEl) return
    newEl.hidden = !show
    if (newToggleEl) newToggleEl.hidden = show || !(ctx && ctx.canCreate)
    if (show) {
      setNewState('', false)
      if (newTitleEl) newTitleEl.focus()
    }
  }

  /** Pull the editor's current selection into the content field (plain text;
   *  the block is pasted back as text, so nothing is lost on the way). */
  function useSelection() {
    try {
      window.Asc.plugin.executeMethod(
        'GetSelectedText',
        [{ Numbering: true, Math: false, TableCellSeparator: '\t', TableRowSeparator: '\n' }],
        function (text) {
          var t = String(text || '').trim()
          if (!t) {
            setNewState('Nothing is selected in the document.', true)
            return
          }
          if (newContentEl) newContentEl.value = t
          setNewState('', false)
        },
      )
    } catch (e) {
      setNewState('Could not read the selection.', true)
    }
  }

  function saveNew() {
    if (saving || !ctx || !ctx.canCreate) return
    var title = newTitleEl ? newTitleEl.value.trim() : ''
    var content = newContentEl ? newContentEl.value.trim() : ''
    if (!title || !content) {
      setNewState('A title and some text are required.', true)
      return
    }
    saving = true
    if (newSaveBtn) newSaveBtn.disabled = true
    setNewState('Saving…', false)
    fetch(ctx.api + '/api/v1/onlyoffice/library', {
      method: 'POST',
      credentials: 'omit',
      mode: 'cors',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + ctx.token },
      body: JSON.stringify({ title: title, content: content }),
    })
      .then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status)
        return res.json()
      })
      .then(function (body) {
        var it = body && body.data
        if (it && it.id) {
          allItems.push({
            id: it.id,
            title: it.title,
            assetType: it.assetType || 'BOILERPLATE',
            tags: Array.isArray(it.tags) ? it.tags : [],
            content: it.content,
            _preview: previewText(it.content),
          })
          allItems.sort(function (a, b) {
            return a.title.localeCompare(b.title)
          })
          renderChips()
          render(searchEl ? searchEl.value : '')
        }
        if (newTitleEl) newTitleEl.value = ''
        if (newContentEl) newContentEl.value = ''
        showNewForm(false)
      })
      .catch(function (err) {
        setNewState('Could not save (' + (err && err.message ? err.message : 'error') + ').', true)
      })
      .then(function () {
        saving = false
        if (newSaveBtn) newSaveBtn.disabled = false
      })
  }

  function boot() {
    listEl = document.getElementById('pf-list')
    newToggleEl = document.getElementById('pf-new-toggle')
    newEl = document.getElementById('pf-new')
    newTitleEl = document.getElementById('pf-new-title')
    newContentEl = document.getElementById('pf-new-content')
    newStateEl = document.getElementById('pf-new-state')
    newSaveBtn = document.getElementById('pf-new-save')
    var selBtn = document.getElementById('pf-new-selection')
    var cancelBtn = document.getElementById('pf-new-cancel')
    if (newToggleEl) {
      newToggleEl.addEventListener('click', function () {
        showNewForm(true)
      })
    }
    if (cancelBtn) {
      cancelBtn.addEventListener('click', function () {
        showNewForm(false)
      })
    }
    if (selBtn) selBtn.addEventListener('click', useSelection)
    if (newSaveBtn) newSaveBtn.addEventListener('click', saveNew)
    searchEl = document.getElementById('pf-search')
    chipsEl = document.getElementById('pf-chips')
    if (searchEl) {
      searchEl.addEventListener('input', function () {
        render(searchEl.value)
      })
    }
    // Options first (the built-in channel); query string only as a fallback for
    // a URL-loaded variation.
    ctx = ctxFromOptions() || ctxFromQuery()
    if (!ctx) {
      // No launch context (e.g. a read-only/viewer session that carries no
      // plugin options): sit idle rather than erroring — there is simply
      // nothing to insert here.
      setState('Open a proposal to load the Library.', false)
      return
    }
    if (newToggleEl) newToggleEl.hidden = !ctx.canCreate
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
