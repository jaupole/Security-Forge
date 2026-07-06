/*
 * Proposal Forge — "Proposal Fields" plugin (right panel).
 *
 * Lists the project's {{field}} placeholders grouped (Project / Pricing / Cover
 * Details / Custom Fields), like the Narrative step's slug dictionary. Clicking
 * a field inserts its {{token}} at the cursor via the plugin API; the token
 * resolves to the real project value on download/convert (server-side).
 *
 * This is a BUILT-IN Document Server plugin: it ships inside the DS image under
 * sdkjs-plugins/pf-fields/ and loads same-origin from the DS, so this frame has
 * NO query string. Launch context (which project + how to reach Proposal Forge)
 * arrives as a short-lived, project-scoped token in the plugin OPTIONS the
 * editor passes: PF sets editorConfig.plugins.options['asc.{…}'] = { ctx, api },
 * and the DS hands the plugin a single merged options object at
 * window.Asc.plugin.info.options (options.all + options[guid] flattened — see
 * ONLYOFFICE sdkjs/common/plugins.js ~L732 for the merge and
 * common/plugins/plugin_base.js ~L641/L644 for info / info.options; verified
 * 2026-07-05). That is the ONLY channel — the token is presented to the plugin
 * data route via `Authorization: Bearer`, never the URL path. No session cookie
 * is used: the token is the whole capability, CORS-scoped to the DS origin.
 */
(function () {
  'use strict'

  var PLUGIN_GUID = 'asc.{B90B3621-D201-40AF-8FFB-87E0DE4CEDAA}'

  // Group order + labels — mirrors the in-app slug dictionary.
  var GROUPS = [
    { source: 'project', label: 'Project' },
    { source: 'pricing', label: 'Pricing' },
    { source: 'cover', label: 'Cover Details' },
    { source: 'custom', label: 'Custom Fields' },
  ]

  var listEl = null
  var searchEl = null
  var allTokens = []
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

  function insertToken(token) {
    // PasteText inserts at the current cursor position (or replaces the
    // selection). Verified against the ONLYOFFICE plugin methods API.
    try {
      window.Asc.plugin.executeMethod('PasteText', ['{{' + token + '}}'])
    } catch (e) {
      /* editor not ready — nothing to do */
    }
  }

  function makeItem(field) {
    var btn = document.createElement('button')
    btn.type = 'button'
    btn.className = 'pf-item'
    btn.title = 'Insert {{' + field.token + '}}'

    var text = document.createElement('span')
    text.className = 'pf-item-text'
    var label = document.createElement('span')
    label.className = 'pf-label'
    label.textContent = field.label || field.token
    text.appendChild(label)
    if (field.value) {
      var value = document.createElement('span')
      value.className = 'pf-value'
      value.textContent = field.value
      text.appendChild(value)
    }

    var token = document.createElement('span')
    token.className = 'pf-token'
    token.textContent = '{{' + field.token + '}}'

    btn.appendChild(text)
    btn.appendChild(token)
    btn.addEventListener('click', function () {
      insertToken(field.token)
    })
    return btn
  }

  function render(filterText) {
    if (!listEl) return
    var needle = (filterText || '').trim().toLowerCase()
    listEl.textContent = ''
    var shown = 0

    for (var g = 0; g < GROUPS.length; g++) {
      var group = GROUPS[g]
      var items = allTokens.filter(function (t) {
        if (t.source !== group.source) return false
        if (!needle) return true
        return (
          (t.label || '').toLowerCase().indexOf(needle) !== -1 ||
          (t.token || '').toLowerCase().indexOf(needle) !== -1 ||
          (t.value || '').toLowerCase().indexOf(needle) !== -1
        )
      })
      if (items.length === 0) continue

      var groupLabel = document.createElement('div')
      groupLabel.className = 'pf-group-label'
      groupLabel.textContent = group.label
      listEl.appendChild(groupLabel)

      var groupBox = document.createElement('div')
      groupBox.className = 'pf-group'
      for (var i = 0; i < items.length; i++) {
        groupBox.appendChild(makeItem(items[i]))
        shown++
      }
      listEl.appendChild(groupBox)
    }

    if (shown === 0) {
      setState(needle ? 'No fields match “' + filterText + '”.' : 'No fields available.', false)
    }
  }

  function loadFields() {
    var url = ctx.api + '/api/v1/onlyoffice/fields'
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
        allTokens = (body && body.data) || []
        render(searchEl ? searchEl.value : '')
      })
      .catch(function (err) {
        setState('Could not load fields (' + (err && err.message ? err.message : 'error') + ').', true)
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
      setState('Open a proposal to load its fields.', false)
      return
    }
    loadFields()
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
