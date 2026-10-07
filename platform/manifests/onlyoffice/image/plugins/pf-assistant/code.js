/*
 * Proposal Forge — "AI Assistant" plugin (right panel).
 *
 * Streams AI-drafted prose from Proposal Forge's own server-side AI proxy and
 * inserts it at the cursor. It never talks to any AI provider directly: it POSTs
 * to PF's OpenAI-compatible proxy (server/routes/onlyoffice-ai.routes.ts), which
 * holds the real provider key server-side, clamps limits, and is scoped to the
 * caller's org+project by the short-lived pf-ai token.
 *
 * This is a BUILT-IN Document Server plugin: it ships inside the DS image under
 * sdkjs-plugins/pf-assistant/ and loads same-origin from the DS, so this frame
 * has NO query string. Launch context arrives as plugin OPTIONS the editor
 * passes: PF sets editorConfig.plugins.options['asc.{…}'] = { base, token, model }
 * and the DS hands the plugin a single merged options object at
 * window.Asc.plugin.info.options (options.all + options[guid] flattened). `base`
 * is already scoped to the token — `${origin}/api/v1/onlyoffice/ai/${token}` — so
 * the plugin only appends `/v1/chat/completions`. That is the PRIMARY channel; a
 * query-string read is a fallback for a URL-loaded variation. No session cookie
 * is used: the token is the whole capability, and the endpoint is CORS-scoped to
 * the DS origin.
 */
(function () {
  'use strict'

  var PLUGIN_GUID = 'asc.{3B9D7F42-8C61-4E05-AF3D-1E6A2C594B70}'
  var DEFAULT_MODEL = 'pf-assistant'

  var promptEl = null
  var sectionSel = null
  var draftBtn = null
  var draftStateEl = null
  var outputEl = null
  var generateBtn = null
  var insertBtn = null
  var ctx = null
  var resultText = ''
  var busy = false
  // Section briefs (the Sections step was folded into the Document step; the
  // brief is edited here, beside the drafting action). Keyed by section id.
  var briefsById = {}
  var briefEl = null
  var guidanceEl = null
  var pagesEl = null
  var rfpEl = null
  var briefSaveBtn = null
  var briefStateEl = null
  var briefDirty = false

  function trimSlashes(s) {
    return String(s || '').replace(/\/+$/, '')
  }

  /** Read the launch context from this frame's own query string (fallback). */
  function ctxFromQuery() {
    try {
      var q = new URLSearchParams(window.location.search)
      var base = trimSlashes(q.get('base'))
      var token = q.get('token')
      if (!base || !token) return null
      return { base: base, token: token, model: q.get('model') || DEFAULT_MODEL, canEditBrief: false }
    } catch (e) {
      return null
    }
  }

  /** Read the launch context from the plugin options the editor passes to this
   *  built-in plugin (primary channel). The DS flattens
   *  editorConfig.plugins.options.all + options[guid] into ONE object at
   *  window.Asc.plugin.info.options; the GUID-keyed / `all` probes are
   *  belt-and-suspenders for a DS build that surfaced the raw (unmerged) shape. */
  function ctxFromOptions() {
    try {
      var info = window.Asc && window.Asc.plugin && window.Asc.plugin.info
      var opts = info && info.options
      if (!opts || typeof opts !== 'object') return null
      var scoped =
        (opts[PLUGIN_GUID] && typeof opts[PLUGIN_GUID] === 'object' && opts[PLUGIN_GUID]) ||
        (opts.all && typeof opts.all === 'object' && opts.all) ||
        opts
      if (scoped && scoped.base && scoped.token) {
        return {
          base: trimSlashes(scoped.base),
          token: String(scoped.token),
          model: scoped.model ? String(scoped.model) : DEFAULT_MODEL,
          // UI hint only: the server enforces the token's own claim.
          canEditBrief: scoped.canEditBrief === true,
        }
      }
    } catch (e) {
      /* ignore */
    }
    return null
  }

  function setOutput(message, isError) {
    if (!outputEl) return
    outputEl.textContent = ''
    var span = document.createElement('span')
    span.className = 'pf-state' + (isError ? ' pf-error' : '')
    span.textContent = message
    outputEl.appendChild(span)
  }

  function renderResult() {
    if (!outputEl) return
    outputEl.textContent = resultText
  }

  function setBusy(next) {
    busy = next
    if (draftBtn) draftBtn.disabled = next || !(sectionSel && sectionSel.value)
    if (generateBtn) generateBtn.disabled = next
    if (insertBtn) insertBtn.disabled = next || resultText.length === 0
    if (generateBtn) generateBtn.textContent = next ? 'Generating…' : 'Generate'
  }

  /** Insert the generated text at the cursor. PasteText inserts plain text at the
   *  current position (or replaces the selection) — no HTML is injected into the
   *  document, so nothing the model returns can smuggle markup into the file. */
  function insertResult() {
    if (!resultText) return
    try {
      window.Asc.plugin.executeMethod('PasteText', [resultText])
    } catch (e) {
      /* editor not ready — nothing to do */
    }
  }

  /** Pull one text delta out of an OpenAI-compatible chat.completion.chunk. */
  function deltaFromEvent(dataLine) {
    if (dataLine === '[DONE]') return null
    try {
      var obj = JSON.parse(dataLine)
      var choice = obj && obj.choices && obj.choices[0]
      var delta = choice && choice.delta
      return delta && typeof delta.content === 'string' ? delta.content : ''
    } catch (e) {
      return ''
    }
  }

  async function generate() {
    if (busy || !ctx) return
    var prompt = (promptEl && promptEl.value ? promptEl.value : '').trim()
    if (!prompt) {
      setOutput('Enter a prompt first.', false)
      return
    }
    resultText = ''
    setBusy(true)
    setOutput('Generating…', false)

    try {
      // credentials omitted on purpose: cross-origin/third-party frame with no
      // session — the token (URL path + Bearer) is the entire authorization.
      var res = await fetch(ctx.base + '/v1/chat/completions', {
        method: 'POST',
        mode: 'cors',
        credentials: 'omit',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer ' + ctx.token,
        },
        body: JSON.stringify({
          model: ctx.model,
          messages: [{ role: 'user', content: prompt }],
          stream: true,
        }),
      })
      if (!res.ok || !res.body) throw new Error('HTTP ' + res.status)

      var reader = res.body.getReader()
      var decoder = new TextDecoder()
      var buffer = ''
      var done = false
      while (!done) {
        var step = await reader.read()
        done = step.done
        if (step.value) buffer += decoder.decode(step.value, { stream: true })

        // SSE events are separated by a blank line.
        var events = buffer.split('\n\n')
        buffer = events.pop() || ''
        for (var i = 0; i < events.length; i++) {
          var lines = events[i].split('\n')
          for (var j = 0; j < lines.length; j++) {
            var line = lines[j]
            if (line.indexOf('data:') !== 0) continue
            var data = line.slice(5).trim()
            if (data === '[DONE]') {
              done = true
              break
            }
            var piece = deltaFromEvent(data)
            if (piece) {
              resultText += piece
              renderResult()
            }
          }
        }
      }

      if (!resultText) setOutput('No text was generated. Try rephrasing your prompt.', false)
      else renderResult()
    } catch (err) {
      setOutput('Could not generate text (' + (err && err.message ? err.message : 'error') + ').', true)
      resultText = ''
    } finally {
      setBusy(false)
    }
  }

  // ── Draft A Section ──────────────────────────────────────────────────────
  // The document is the only place the proposal's text lives, so AI drafting of
  // a section happens here: pick one of the proposal's AI sections, and the
  // draft — built from the same brief as the first assembly (guidance,
  // references, assets, RFP, pricing) — streams back and is pasted at the
  // cursor as formatted HTML. Nothing is written to the section itself.
  function setDraftState(message, isError) {
    if (!draftStateEl) return
    draftStateEl.textContent = message || ''
    draftStateEl.className = 'pf-draft-state' + (isError ? ' pf-error' : '')
  }

  async function loadSections() {
    if (!ctx || !sectionSel) return
    try {
      var res = await fetch(ctx.base + '/sections', {
        method: 'GET',
        mode: 'cors',
        credentials: 'omit',
        headers: { Authorization: 'Bearer ' + ctx.token },
      })
      if (!res.ok) throw new Error('HTTP ' + res.status)
      var body = await res.json()
      var items = (body && body.data) || []
      sectionSel.textContent = ''
      briefsById = {}
      var placeholder = document.createElement('option')
      placeholder.value = ''
      placeholder.textContent = items.length ? 'Choose a section…' : 'No AI sections in this proposal'
      sectionSel.appendChild(placeholder)
      for (var i = 0; i < items.length; i++) {
        var opt = document.createElement('option')
        opt.value = items[i].id
        opt.textContent = items[i].title
        sectionSel.appendChild(opt)
        briefsById[items[i].id] = items[i]
      }
      sectionSel.disabled = items.length === 0
      if (draftBtn) draftBtn.disabled = true
      showBrief('')
    } catch (err) {
      setDraftState('Could not load the sections (' + (err && err.message ? err.message : 'error') + ').', true)
    }
  }

  // ── The brief ────────────────────────────────────────────────────────────
  // Guidance, target length and the RFP toggle for the chosen section — what
  // Draft At Cursor (and Draft With AI) write from. Saved through the same
  // token: the server accepts the write only for an EDIT session, so a review
  // session sees the brief read-only. References, assets and section templates
  // stay on the Document step's Section Briefs dialog.
  function setBriefState(message, isError) {
    if (!briefStateEl) return
    briefStateEl.textContent = message || ''
    briefStateEl.className = 'pf-draft-state pf-brief-state' + (isError ? ' pf-error' : '')
  }

  function showBrief(sectionId) {
    if (!briefEl) return
    var brief = sectionId ? briefsById[sectionId] : null
    briefDirty = false
    if (!brief) {
      briefEl.hidden = true
      return
    }
    var editable = !!(ctx && ctx.canEditBrief)
    guidanceEl.value = brief.userGuidance || ''
    pagesEl.value = String(brief.targetPages || 2)
    rfpEl.checked = brief.includeRfp === true
    guidanceEl.readOnly = !editable
    pagesEl.disabled = !editable
    rfpEl.disabled = !editable
    briefSaveBtn.hidden = !editable
    briefSaveBtn.disabled = true
    setBriefState(editable ? '' : 'Read-only in a review session.', false)
    briefEl.hidden = false
  }

  function markBriefDirty() {
    if (!ctx || !ctx.canEditBrief) return
    briefDirty = true
    if (briefSaveBtn) briefSaveBtn.disabled = busy
    setBriefState('Unsaved changes.', false)
  }

  /** PUT the brief; resolves true when saved (or nothing to save). */
  async function saveBrief() {
    if (!ctx || !ctx.canEditBrief || !sectionSel || !sectionSel.value || !briefDirty) return true
    var sectionId = sectionSel.value
    var pages = parseInt(pagesEl.value, 10)
    if (!(pages >= 1 && pages <= 40)) {
      setBriefState('Target length must be between 1 and 40 pages.', true)
      return false
    }
    var payload = {
      userGuidance: guidanceEl.value.trim() ? guidanceEl.value : null,
      targetPages: pages,
      includeRfp: rfpEl.checked,
    }
    briefSaveBtn.disabled = true
    setBriefState('Saving…', false)
    try {
      var res = await fetch(ctx.base + '/sections/' + encodeURIComponent(sectionId), {
        method: 'PUT',
        mode: 'cors',
        credentials: 'omit',
        headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + ctx.token },
        body: JSON.stringify(payload),
      })
      if (!res.ok) throw new Error('HTTP ' + res.status)
      var body = await res.json()
      if (body && body.data) briefsById[sectionId] = body.data
      briefDirty = false
      setBriefState('Brief saved.', false)
      return true
    } catch (err) {
      briefSaveBtn.disabled = false
      setBriefState('Could not save the brief (' + (err && err.message ? err.message : 'error') + ').', true)
      return false
    }
  }

  async function draftSection() {
    if (busy || !ctx || !sectionSel || !sectionSel.value) return
    // An unsaved brief is what the user means to draft from — save it first.
    if (briefDirty && !(await saveBrief())) return
    var sectionId = sectionSel.value
    var title = sectionSel.options[sectionSel.selectedIndex].textContent
    var html = ''
    var chars = 0
    setBusy(true)
    setDraftState('Drafting “' + title + '”…', false)
    try {
      var res = await fetch(ctx.base + '/draft-section', {
        method: 'POST',
        mode: 'cors',
        credentials: 'omit',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer ' + ctx.token,
        },
        body: JSON.stringify({ sectionId: sectionId }),
      })
      if (!res.ok || !res.body) throw new Error('HTTP ' + res.status)
      var reader = res.body.getReader()
      var decoder = new TextDecoder()
      var buffer = ''
      var done = false
      var failed = null
      while (!done) {
        var step = await reader.read()
        done = step.done
        if (step.value) buffer += decoder.decode(step.value, { stream: true })
        var events = buffer.split('\n\n')
        buffer = events.pop() || ''
        for (var i = 0; i < events.length; i++) {
          var lines = events[i].split('\n')
          for (var j = 0; j < lines.length; j++) {
            var line = lines[j]
            if (line.indexOf('data:') !== 0) continue
            var data = line.slice(5).trim()
            if (data === '[DONE]') {
              done = true
              break
            }
            var ev = null
            try {
              ev = JSON.parse(data)
            } catch (e) {
              ev = null
            }
            if (!ev) continue
            if (ev.type === 'chunk' && typeof ev.content === 'string') {
              chars += ev.content.length
              setDraftState('Drafting “' + title + '”… ' + chars + ' characters', false)
            } else if (ev.type === 'done' && typeof ev.content === 'string') {
              html = ev.content
            } else if (ev.type === 'error') {
              failed = ev.error || 'Generation failed'
            }
          }
        }
      }
      if (failed && !html) throw new Error(failed)
      if (!html) throw new Error('No text was generated')
      window.Asc.plugin.executeMethod('PasteHtml', [html])
      setDraftState('Inserted “' + title + '” at the cursor.' + (failed ? ' (partial: ' + failed + ')' : ''), false)
    } catch (err) {
      setDraftState('Could not draft the section (' + (err && err.message ? err.message : 'error') + ').', true)
    } finally {
      setBusy(false)
    }
  }

  function boot() {
    promptEl = document.getElementById('pf-prompt')
    sectionSel = document.getElementById('pf-section')
    draftBtn = document.getElementById('pf-draft')
    draftStateEl = document.getElementById('pf-draft-state')
    briefEl = document.getElementById('pf-brief')
    guidanceEl = document.getElementById('pf-guidance')
    pagesEl = document.getElementById('pf-pages')
    rfpEl = document.getElementById('pf-rfp')
    briefSaveBtn = document.getElementById('pf-brief-save')
    briefStateEl = document.getElementById('pf-brief-state')
    if (sectionSel) {
      sectionSel.addEventListener('change', function () {
        if (draftBtn) draftBtn.disabled = busy || !sectionSel.value
        showBrief(sectionSel.value)
      })
    }
    if (draftBtn) draftBtn.addEventListener('click', draftSection)
    if (guidanceEl) guidanceEl.addEventListener('input', markBriefDirty)
    if (pagesEl) pagesEl.addEventListener('input', markBriefDirty)
    if (rfpEl) rfpEl.addEventListener('change', markBriefDirty)
    if (briefSaveBtn) briefSaveBtn.addEventListener('click', function () { void saveBrief() })
    outputEl = document.getElementById('pf-output')
    generateBtn = document.getElementById('pf-generate')
    insertBtn = document.getElementById('pf-insert')

    if (generateBtn) generateBtn.addEventListener('click', generate)
    if (insertBtn) insertBtn.addEventListener('click', insertResult)

    // Options first (the built-in channel); query string only as a fallback.
    ctx = ctxFromOptions() || ctxFromQuery()
    if (ctx) loadSections()
    if (!ctx) {
      // No launch context (e.g. a read-only/viewer session that carries no
      // plugin options): sit idle rather than erroring.
      if (generateBtn) generateBtn.disabled = true
      setOutput('Open a proposal to use the assistant.', false)
    }
  }

  // ── Obligatory ONLYOFFICE plugin events ──────────────────────────────────
  window.Asc = window.Asc || {}
  window.Asc.plugin = window.Asc.plugin || {}

  // init fires once the editor <-> plugin bridge is ready; window.Asc.plugin.info
  // (and info.options) is populated by then, so the options channel can be read.
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
