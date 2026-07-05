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
  var outputEl = null
  var generateBtn = null
  var insertBtn = null
  var ctx = null
  var resultText = ''
  var busy = false

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
      return { base: base, token: token, model: q.get('model') || DEFAULT_MODEL }
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

  function boot() {
    promptEl = document.getElementById('pf-prompt')
    outputEl = document.getElementById('pf-output')
    generateBtn = document.getElementById('pf-generate')
    insertBtn = document.getElementById('pf-insert')

    if (generateBtn) generateBtn.addEventListener('click', generate)
    if (insertBtn) insertBtn.addEventListener('click', insertResult)

    // Options first (the built-in channel); query string only as a fallback.
    ctx = ctxFromOptions() || ctxFromQuery()
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
